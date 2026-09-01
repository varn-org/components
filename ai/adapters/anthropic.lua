-- the anthropic messages api, translated in both directions so callers keep writing openai-shaped requests and reading openai-shaped responses
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

local anthropicVersion = "2023-06-01"

-- anthropic names its stop reasons differently, and a caller branching on finish_reason expects the openai spelling
local finishReasons = {
    end_turn = "stop",
    stop_sequence = "stop",
    max_tokens = "length",
    tool_use = "tool_calls",
    pause_turn = "stop",
    refusal = "content_filter",
}

local function headers(client)
    local out = { ["Content-Type"] = "application/json", ["anthropic-version"] = anthropicVersion }
    if client.apiKey then
        out["x-api-key"] = client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- a data url carries the media type and the payload inline, which is how anthropic wants an inline image
local function imageSource(url)
    local mediaType, data = url:match("^data:([%w%-%./+]+);base64,(.+)$")
    if mediaType then
        return { type = "base64", media_type = mediaType, data = data }
    end

    return { type = "url", url = url }
end

local function contentBlocks(content)
    if type(content) == "string" then
        return { { type = "text", text = content } }
    end

    local blocks = {}
    for _, part in ipairs(content or {}) do
        if part.type == "text" then
            blocks[#blocks + 1] = { type = "text", text = part.text }
        elseif part.type == "image_url" then
            blocks[#blocks + 1] = { type = "image", source = imageSource(part.image_url.url) }
        end
    end

    return blocks
end

-- an assistant turn that called tools becomes text blocks followed by one tool_use block per call
local function assistantBlocks(message)
    local blocks = {}
    if message.content and message.content ~= "" then
        for _, block in ipairs(contentBlocks(message.content)) do
            blocks[#blocks + 1] = block
        end
    end

    for _, call in ipairs(message.tool_calls or {}) do
        local arguments = call["function"] and call["function"].arguments
        blocks[#blocks + 1] = {
            type = "tool_use",
            id = call.id,
            name = call["function"] and call["function"].name,
            input = arguments and arguments ~= "" and json.decode(arguments) or {},
        }
    end

    return blocks
end

-- openai carries the system prompt as a message while anthropic takes it beside the conversation
local function splitMessages(messages)
    local system = {}
    local turns = {}

    for _, message in ipairs(messages or {}) do
        if message.role == "system" then
            for _, block in ipairs(contentBlocks(message.content)) do
                system[#system + 1] = block
            end
        elseif message.role == "tool" then
            turns[#turns + 1] = {
                role = "user",
                content = { { type = "tool_result", tool_use_id = message.tool_call_id, content = message.content } },
            }
        elseif message.role == "assistant" then
            turns[#turns + 1] = { role = "assistant", content = assistantBlocks(message) }
        else
            turns[#turns + 1] = { role = message.role, content = contentBlocks(message.content) }
        end
    end

    return (#system > 0 and system or nil), turns
end

local function wireTools(tools)
    if not tools then
        return nil
    end

    local out = {}
    for _, tool in ipairs(tools) do
        local fn = tool["function"] or tool
        out[#out + 1] = { name = fn.name, description = fn.description, input_schema = fn.parameters or fn.input_schema }
    end

    return out
end

local function wireToolChoice(choice)
    if choice == nil then
        return nil
    end

    if choice == "auto" then
        return { type = "auto" }
    end
    if choice == "required" then
        return { type = "any" }
    end
    if choice == "none" then
        return { type = "none" }
    end

    local fn = type(choice) == "table" and choice["function"]
    if fn then
        return { type = "tool", name = fn.name }
    end

    error("ai: anthropic does not understand tool_choice " .. tostring(choice), 0)
end

-- anthropic requires max_tokens, so a request that omits it is answered with a clear error rather than a silent default
local function buildBody(client, request)
    if not request.max_tokens then
        error("ai: anthropic requires max_tokens on every request", 0)
    end

    local system, messages = splitMessages(request.messages)
    local body = wire.body(client, request)

    body.messages = messages
    body.system = request.system or system
    body.tools = wireTools(request.tools)
    body.tool_choice = wireToolChoice(request.tool_choice)
    body.stop = nil
    body.stop_sequences = request.stop_sequences or request.stop

    return body
end

local function readUsage(usage)
    if not usage then
        return nil
    end

    local input = usage.input_tokens or 0
    local output = usage.output_tokens or 0

    return { prompt_tokens = input, completion_tokens = output, total_tokens = input + output }
end

-- the content blocks of a reply become one openai message, with tool_use blocks lifted into tool_calls
local function readMessage(content)
    local message = { role = "assistant" }
    local text = {}

    for _, block in ipairs(content or {}) do
        if block.type == "text" then
            text[#text + 1] = block.text
        elseif block.type == "thinking" then
            message.reasoning_content = (message.reasoning_content or "") .. (block.thinking or "")
        elseif block.type == "tool_use" then
            message.tool_calls = message.tool_calls or {}
            message.tool_calls[#message.tool_calls + 1] = {
                index = #message.tool_calls,
                id = block.id,
                type = "function",
                ["function"] = { name = block.name, arguments = json.encode(block.input or {}) },
            }
        end
    end

    message.content = #text > 0 and table.concat(text) or nil
    return message
end

function adapter.completion(client, request)
    local data = transport.sendJson({
        url = client.baseUrl .. "/v1/messages",
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    return wire.completionResponse({
        id = data.id,
        model = data.model,
        choices = {
            {
                index = 0,
                message = readMessage(data.content),
                finish_reason = finishReasons[data.stop_reason] or data.stop_reason,
            },
        },
        usage = readUsage(data.usage),
    })
end

-- anthropic takes the batch requests inline rather than through an uploaded file, so each entry is built here from the same request shape a completion uses
function adapter.batchCreate(client, request)
    local requests = {}
    for _, entry in ipairs(request.requests or {}) do
        requests[#requests + 1] = {
            custom_id = entry.custom_id,
            params = buildBody({ model = entry.model or client.model }, entry.params or entry),
        }
    end

    return transport.sendJson({
        url = client.baseUrl .. "/v1/messages/batches",
        method = "POST",
        headers = headers(client),
        json = { requests = requests },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

local function batchId(request)
    local id = request.batch_id
    if not id then
        error("ai: this call needs batch_id", 0)
    end

    return id
end

function adapter.batchRetrieve(client, request)
    return transport.sendJson({
        url = client.baseUrl .. "/v1/messages/batches/" .. batchId(request),
        method = "GET",
        headers = headers(client),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchCancel(client, request)
    return transport.sendJson({
        url = client.baseUrl .. "/v1/messages/batches/" .. batchId(request) .. "/cancel",
        method = "POST",
        headers = headers(client),
        json = {},
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchList(client, request)
    return transport.sendJson({
        url = client.baseUrl .. "/v1/messages/batches",
        method = "GET",
        headers = headers(client),
        query = { limit = request.limit, after_id = request.after },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchResults(client, request)
    local batch = adapter.batchRetrieve(client, request)
    local url = batch.results_url
    if not url then
        error(string.format("%s: batch %s has no results yet (status %s)", client.provider, batchId(request), tostring(batch.processing_status)), 0)
    end

    local response = transport.send({
        url = url,
        method = "GET",
        headers = headers(client),
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    local records = {}
    for line in response.body:gmatch("[^\n]+") do
        records[#records + 1] = json.decode(line)
    end

    return { batch = batch, results = records }
end

function adapter.streamCompletion(client, request, onChunk)
    local body = buildBody(client, request)
    body.stream = true

    local message = { role = "assistant" }
    local blocks = {}
    local state = { id = nil, model = nil, finish_reason = nil, usage = nil }

    local function emit(delta, finishReason)
        onChunk(wire.chunk({ id = state.id, model = state.model or client.model, delta = delta, finish_reason = finishReason }))
    end

    transport.sse({
        url = client.baseUrl .. "/v1/messages",
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = client.timeoutSeconds,
    }, function(name, payload)
        local event = json.decode(payload)

        if name == "message_start" then
            state.id = event.message and event.message.id
            state.model = event.message and event.message.model
            state.usage = readUsage(event.message and event.message.usage)
            emit({ role = "assistant" })
            return
        end

        if name == "content_block_start" then
            local block = event.content_block or {}
            blocks[event.index] = block

            if block.type == "tool_use" then
                message.tool_calls = message.tool_calls or {}
                local index = #message.tool_calls
                block.slot = index + 1
                message.tool_calls[block.slot] =
                    { index = index, id = block.id, type = "function", ["function"] = { name = block.name, arguments = "" } }
                emit({ tool_calls = { { index = index, id = block.id, type = "function", ["function"] = { name = block.name, arguments = "" } } } })
            end
            return
        end

        if name == "content_block_delta" then
            local delta = event.delta or {}
            local block = blocks[event.index] or {}

            if delta.type == "text_delta" then
                message.content = (message.content or "") .. delta.text
                emit({ content = delta.text })
            elseif delta.type == "thinking_delta" then
                message.reasoning_content = (message.reasoning_content or "") .. delta.thinking
                emit({ reasoning_content = delta.thinking })
            elseif delta.type == "input_json_delta" and block.slot then
                local call = message.tool_calls[block.slot]
                call["function"].arguments = call["function"].arguments .. delta.partial_json
                emit({ tool_calls = { { index = call.index, ["function"] = { arguments = delta.partial_json } } } })
            end
            return
        end

        if name == "message_delta" then
            local stop = event.delta and event.delta.stop_reason
            state.finish_reason = finishReasons[stop] or stop

            if event.usage then
                local usage = readUsage(event.usage)
                local prompt = state.usage and state.usage.prompt_tokens or 0
                state.usage = {
                    prompt_tokens = prompt,
                    completion_tokens = usage.completion_tokens,
                    total_tokens = prompt + usage.completion_tokens,
                }
            end

            emit({}, state.finish_reason)
        end
    end, client.provider)

    return wire.completionResponse({
        id = state.id,
        model = state.model or client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

return adapter
