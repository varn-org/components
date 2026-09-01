-- the cohere v2 api, whose chat wire is close to openai but names its fields and stop reasons differently
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

local finishReasons = {
    COMPLETE = "stop",
    STOP_SEQUENCE = "stop",
    MAX_TOKENS = "length",
    TOOL_CALL = "tool_calls",
    ERROR = "stop",
}

-- cohere carries every message content as blocks and expects a tool result under its own role
local function wireMessages(messages)
    local out = {}

    for _, message in ipairs(messages or {}) do
        if message.role == "tool" then
            out[#out + 1] = { role = "tool", tool_call_id = message.tool_call_id, content = message.content }
        elseif message.role == "assistant" then
            out[#out + 1] = { role = "assistant", content = message.content, tool_calls = message.tool_calls }
        elseif type(message.content) == "table" then
            local blocks = {}
            for _, part in ipairs(message.content) do
                if part.type == "text" then
                    blocks[#blocks + 1] = { type = "text", text = part.text }
                elseif part.type == "image_url" then
                    blocks[#blocks + 1] = { type = "image_url", image_url = { url = part.image_url.url } }
                end
            end
            out[#out + 1] = { role = message.role, content = blocks }
        else
            out[#out + 1] = { role = message.role, content = message.content }
        end
    end

    return out
end

local function buildBody(client, request)
    return {
        model = client.model,
        messages = wireMessages(request.messages),
        temperature = request.temperature,
        p = request.top_p,
        max_tokens = request.max_tokens,
        stop_sequences = type(request.stop) == "table" and request.stop or (request.stop and { request.stop }),
        tools = request.tools,
        tool_choice = request.tool_choice,
        response_format = request.response_format,
        seed = request.seed,
    }
end

local function readUsage(usage)
    local tokens = usage and usage.tokens
    if not tokens then
        return nil
    end

    local input = tokens.input_tokens or 0
    local output = tokens.output_tokens or 0

    return { prompt_tokens = input, completion_tokens = output, total_tokens = input + output }
end

local function readMessage(source)
    local message = { role = "assistant" }
    local text = {}

    for _, block in ipairs(source and source.content or {}) do
        if block.type == "text" then
            text[#text + 1] = block.text
        end
    end

    for index, call in ipairs(source and source.tool_calls or {}) do
        message.tool_calls = message.tool_calls or {}
        message.tool_calls[index] = {
            index = index - 1,
            id = call.id,
            type = "function",
            ["function"] = { name = call["function"] and call["function"].name, arguments = call["function"] and call["function"].arguments },
        }
    end

    message.content = #text > 0 and table.concat(text) or nil
    return message
end

function adapter.completion(client, request)
    local data = transport.sendJson({
        url = client.baseUrl .. "/v2/chat",
        method = "POST",
        headers = wire.headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    return wire.completionResponse({
        id = data.id,
        model = client.model,
        choices = {
            {
                index = 0,
                message = readMessage(data.message),
                finish_reason = finishReasons[data.finish_reason] or data.finish_reason,
            },
        },
        usage = readUsage(data.usage),
    })
end

function adapter.streamCompletion(client, request, onChunk)
    local body = buildBody(client, request)
    body.stream = true

    local message = { role = "assistant" }
    local state = { id = nil, finish_reason = nil, usage = nil }

    transport.sse({
        url = client.baseUrl .. "/v2/chat",
        method = "POST",
        headers = wire.headers(client),
        json = body,
        timeoutSeconds = client.timeoutSeconds,
    }, function(_, payload)
        local event = json.decode(payload)

        if event.type == "message-start" then
            state.id = event.id
            onChunk(wire.chunk({ id = state.id, model = client.model, delta = { role = "assistant" } }))
            return
        end

        if event.type == "content-delta" then
            local text = event.delta and event.delta.message and event.delta.message.content and event.delta.message.content.text
            if text and text ~= "" then
                message.content = (message.content or "") .. text
                onChunk(wire.chunk({ id = state.id, model = client.model, delta = { content = text } }))
            end
            return
        end

        if event.type == "tool-call-start" then
            local call = event.delta and event.delta.message and event.delta.message.tool_calls
            if call then
                message.tool_calls = message.tool_calls or {}
                local index = #message.tool_calls
                message.tool_calls[index + 1] = {
                    index = index,
                    id = call.id,
                    type = "function",
                    ["function"] = { name = call["function"] and call["function"].name or "", arguments = "" },
                }
            end
            return
        end

        if event.type == "tool-call-delta" then
            local fragment = event.delta and event.delta.message and event.delta.message.tool_calls
            local arguments = fragment and fragment["function"] and fragment["function"].arguments
            local current = message.tool_calls and message.tool_calls[#message.tool_calls]
            if arguments and current then
                current["function"].arguments = current["function"].arguments .. arguments
                onChunk(wire.chunk({
                    id = state.id,
                    model = client.model,
                    delta = { tool_calls = { { index = current.index, ["function"] = { arguments = arguments } } } },
                }))
            end
            return
        end

        if event.type == "message-end" then
            local delta = event.delta or {}
            state.finish_reason = finishReasons[delta.finish_reason] or delta.finish_reason
            state.usage = readUsage(delta.usage)
            onChunk(wire.chunk({ id = state.id, model = client.model, delta = {}, finish_reason = state.finish_reason }))
        end
    end, client.provider)

    return wire.completionResponse({
        id = state.id,
        model = client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

function adapter.embedding(client, request)
    local inputs = type(request.input) == "table" and request.input or { request.input }

    local data = transport.sendJson({
        url = client.baseUrl .. "/v2/embed",
        method = "POST",
        headers = wire.headers(client),
        json = {
            model = client.model,
            texts = inputs,
            input_type = request.input_type or "search_document",
            embedding_types = { "float" },
        },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    local items = {}
    for index, vector in ipairs(data.embeddings and data.embeddings.float or {}) do
        items[#items + 1] = { object = "embedding", index = index - 1, embedding = vector }
    end

    return { object = "list", data = items, model = client.model, usage = readUsage(data.meta) }
end

function adapter.rerank(client, request)
    return transport.sendJson({
        url = client.baseUrl .. "/v2/rerank",
        method = "POST",
        headers = wire.headers(client),
        json = {
            model = client.model,
            query = request.query,
            documents = request.documents,
            top_n = request.top_n,
        },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

return adapter
