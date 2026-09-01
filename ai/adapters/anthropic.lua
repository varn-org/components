-- anthropic claude messages adapter covering text, vision, tool use, and extended thinking over the messages api
local json = require("json")
local transport = require("ai.http")

local adapter = {}

local DEFAULT_MAX_TOKENS = 4096
local API_VERSION = "2023-06-01"

local function headers(client)
    local out = {
        ["Content-Type"] = "application/json",
        ["anthropic-version"] = API_VERSION,
    }
    if client.apiKey then
        out["x-api-key"] = client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- claude carries images as typed source blocks rather than the openai image_url shape
local function imageBlock(part)
    if part.url then
        return { type = "image", source = { type = "url", url = part.url } }
    end

    return { type = "image", source = { type = "base64", media_type = part.mediaType or "image/png", data = part.base64 } }
end

local function contentBlocks(content)
    if type(content) == "string" then
        return content
    end

    local blocks = {}
    for _, part in ipairs(content) do
        if part.type == "text" then
            blocks[#blocks + 1] = { type = "text", text = part.text }
        elseif part.type == "image" then
            blocks[#blocks + 1] = imageBlock(part)
        end
    end

    return blocks
end

-- folds the normalized transcript into claude messages, lifting system text to the top-level field and turning tool calls and tool results into typed blocks
local function buildMessages(request)
    local systemParts = {}
    if request.system then
        systemParts[#systemParts + 1] = request.system
    end

    local messages = {}
    for _, message in ipairs(request.messages or {}) do
        if message.role == "system" then
            systemParts[#systemParts + 1] = message.content
        elseif message.role == "tool" then
            messages[#messages + 1] = {
                role = "user",
                content = { { type = "tool_result", tool_use_id = message.toolCallId, content = message.content } },
            }
        elseif message.role == "assistant" and message.toolCalls then
            local blocks = {}
            if type(message.content) == "string" and message.content ~= "" then
                blocks[#blocks + 1] = { type = "text", text = message.content }
            end
            for _, call in ipairs(message.toolCalls) do
                blocks[#blocks + 1] = { type = "tool_use", id = call.id, name = call.name, input = json.decode(call.arguments) }
            end
            messages[#messages + 1] = { role = "assistant", content = blocks }
        else
            messages[#messages + 1] = { role = message.role, content = contentBlocks(message.content) }
        end
    end

    local system = #systemParts > 0 and table.concat(systemParts, "\n\n") or nil
    return messages, system
end

local function buildTools(tools)
    if not tools then
        return nil
    end

    local out = {}
    for _, tool in ipairs(tools) do
        out[#out + 1] = { name = tool.name, description = tool.description, input_schema = tool.parameters }
    end

    return out
end

local function buildBody(client, request, stream)
    local messages, system = buildMessages(request)

    local body = {
        model = request.model or client.model,
        max_tokens = request.maxTokens or DEFAULT_MAX_TOKENS,
        messages = messages,
        system = system,
        temperature = request.temperature,
        top_p = request.topP,
        stop_sequences = request.stop,
        tools = buildTools(request.tools),
        tool_choice = request.toolChoice,
        thinking = request.thinking,
    }

    if stream then
        body.stream = true
    end

    for key, value in pairs(request.extra or {}) do
        body[key] = value
    end

    return body
end

local function readUsage(usage)
    if not usage then
        return nil
    end

    return {
        inputTokens = usage.input_tokens,
        outputTokens = usage.output_tokens,
        totalTokens = (usage.input_tokens or 0) + (usage.output_tokens or 0),
    }
end

function adapter.generate(client, request)
    local data = transport.sendJson({
        url = client.baseUrl .. "/v1/messages",
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request, false),
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, client.provider)

    local text = {}
    local reasoning = {}
    local toolCalls = {}
    for _, block in ipairs(data.content or {}) do
        if block.type == "text" then
            text[#text + 1] = block.text
        elseif block.type == "thinking" then
            reasoning[#reasoning + 1] = block.thinking
        elseif block.type == "tool_use" then
            toolCalls[#toolCalls + 1] = { id = block.id, name = block.name, arguments = json.encode(block.input) }
        end
    end

    return {
        text = #text > 0 and table.concat(text) or nil,
        reasoning = #reasoning > 0 and table.concat(reasoning) or nil,
        finishReason = data.stop_reason,
        toolCalls = #toolCalls > 0 and toolCalls or nil,
        usage = readUsage(data.usage),
        raw = data,
    }
end

function adapter.stream(client, request, onEvent)
    local text = {}
    local reasoning = {}
    local blocks = {}
    local finishReason
    local usage = { inputTokens = 0, outputTokens = 0, totalTokens = 0 }

    transport.sse({
        url = client.baseUrl .. "/v1/messages",
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request, true),
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, function(eventName, payload)
        local event = json.decode(payload)

        if eventName == "message_start" then
            local startUsage = readUsage(event.message and event.message.usage)
            if startUsage then
                usage.inputTokens = startUsage.inputTokens or 0
            end
        elseif eventName == "content_block_start" then
            local block = event.content_block or {}
            blocks[event.index] = { type = block.type, id = block.id, name = block.name, arguments = "" }
        elseif eventName == "content_block_delta" then
            local delta = event.delta or {}
            if delta.type == "text_delta" then
                text[#text + 1] = delta.text
                onEvent({ type = "text", delta = delta.text })
            elseif delta.type == "thinking_delta" then
                reasoning[#reasoning + 1] = delta.thinking
                onEvent({ type = "reasoning", delta = delta.thinking })
            elseif delta.type == "input_json_delta" then
                local block = blocks[event.index]
                if block then
                    block.arguments = block.arguments .. delta.partial_json
                end
            end
        elseif eventName == "message_delta" then
            if event.delta and event.delta.stop_reason then
                finishReason = event.delta.stop_reason
            end
            if event.usage and event.usage.output_tokens then
                usage.outputTokens = event.usage.output_tokens
            end
        end
    end, client.provider)

    -- collect content blocks in their emitted index order since pairs() over the sparse index map is unordered
    local indices = {}
    for index in pairs(blocks) do
        indices[#indices + 1] = index
    end
    table.sort(indices)

    local toolCalls = {}
    for _, index in ipairs(indices) do
        local block = blocks[index]
        if block.type == "tool_use" then
            toolCalls[#toolCalls + 1] = { id = block.id, name = block.name, arguments = block.arguments }
        end
    end

    usage.totalTokens = (usage.inputTokens or 0) + (usage.outputTokens or 0)
    local result = {
        text = #text > 0 and table.concat(text) or nil,
        reasoning = #reasoning > 0 and table.concat(reasoning) or nil,
        finishReason = finishReason,
        toolCalls = #toolCalls > 0 and toolCalls or nil,
        usage = usage,
    }

    onEvent({ type = "done", finishReason = finishReason, usage = usage, text = result.text, toolCalls = result.toolCalls })
    return result
end

return adapter
