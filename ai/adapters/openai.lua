-- openai chat completions adapter, also the baseline for every openai-compatible provider (grok, deepseek, kimi, groq, together, openrouter, ollama) selected through a different base url
local json = require("json")
local transport = require("ai.http")

local adapter = {}

local function headers(client)
    local out = { ["Content-Type"] = "application/json" }
    if client.apiKey then
        out["Authorization"] = "Bearer " .. client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- converts a normalized message into the chat wire shape, supporting string content, multimodal parts, and tool results
local function wireMessage(message)
    if message.role == "tool" then
        return { role = "tool", tool_call_id = message.toolCallId, content = message.content }
    end

    if type(message.content) == "string" or message.content == nil then
        local out = { role = message.role, content = message.content }
        if message.toolCalls then
            local calls = {}
            for _, call in ipairs(message.toolCalls) do
                calls[#calls + 1] = { id = call.id, type = "function", ["function"] = { name = call.name, arguments = call.arguments } }
            end
            out.tool_calls = calls
        end
        return out
    end

    local parts = {}
    for _, part in ipairs(message.content) do
        if part.type == "text" then
            parts[#parts + 1] = { type = "text", text = part.text }
        elseif part.type == "image" then
            parts[#parts + 1] = { type = "image_url", image_url = { url = part.url, detail = part.detail } }
        end
    end

    return { role = message.role, content = parts }
end

local function wireTools(tools)
    if not tools then
        return nil
    end

    local out = {}
    for _, tool in ipairs(tools) do
        out[#out + 1] = { type = "function", ["function"] = { name = tool.name, description = tool.description, parameters = tool.parameters } }
    end

    return out
end

local function buildBody(client, request, stream)
    local messages = {}
    if request.system then
        messages[#messages + 1] = { role = "system", content = request.system }
    end
    for _, message in ipairs(request.messages or {}) do
        messages[#messages + 1] = wireMessage(message)
    end

    local body = {
        model = request.model or client.model,
        messages = messages,
        temperature = request.temperature,
        top_p = request.topP,
        stop = request.stop,
        max_completion_tokens = request.maxTokens,
        tools = wireTools(request.tools),
        tool_choice = request.toolChoice,
        response_format = request.responseFormat,
        reasoning_effort = request.reasoningEffort,
    }

    if stream then
        body.stream = true
        body.stream_options = { include_usage = true }
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
        inputTokens = usage.prompt_tokens,
        outputTokens = usage.completion_tokens,
        totalTokens = usage.total_tokens,
    }
end

local function readToolCalls(message)
    if not message or not message.tool_calls then
        return nil
    end

    local out = {}
    for _, call in ipairs(message.tool_calls) do
        out[#out + 1] = {
            id = call.id,
            name = call["function"] and call["function"].name,
            arguments = call["function"] and call["function"].arguments,
        }
    end

    return out
end

function adapter.generate(client, request)
    local body = buildBody(client, request, false)
    local data = transport.sendJson({
        url = client.baseUrl .. "/chat/completions",
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, client.provider)

    local choice = data.choices and data.choices[1] or {}
    local message = choice.message or {}

    return {
        text = message.content,
        reasoning = message.reasoning_content or message.reasoning,
        finishReason = choice.finish_reason,
        toolCalls = readToolCalls(message),
        usage = readUsage(data.usage),
        raw = data,
    }
end

function adapter.stream(client, request, onEvent)
    local body = buildBody(client, request, true)

    local text = {}
    local reasoning = {}
    local toolCalls = {}
    local finishReason
    local usage

    local function accumulateToolCall(delta)
        local index = (delta.index or 0) + 1
        local call = toolCalls[index]
        if not call then
            call = { id = delta.id, name = "", arguments = "" }
            toolCalls[index] = call
        end
        if delta.id then
            call.id = delta.id
        end
        if delta["function"] then
            if delta["function"].name then
                call.name = call.name .. delta["function"].name
            end
            if delta["function"].arguments then
                call.arguments = call.arguments .. delta["function"].arguments
            end
        end
    end

    transport.sse({
        url = client.baseUrl .. "/chat/completions",
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, function(_, payload)
        if payload == "[DONE]" then
            return
        end

        local chunk = json.decode(payload)
        if chunk.usage then
            usage = readUsage(chunk.usage)
        end

        local choice = chunk.choices and chunk.choices[1]
        if not choice then
            return
        end

        if choice.finish_reason then
            finishReason = choice.finish_reason
        end

        local delta = choice.delta or {}
        if delta.content and delta.content ~= "" then
            text[#text + 1] = delta.content
            onEvent({ type = "text", delta = delta.content })
        end

        local reasoningDelta = delta.reasoning_content or delta.reasoning
        if reasoningDelta and reasoningDelta ~= "" then
            reasoning[#reasoning + 1] = reasoningDelta
            onEvent({ type = "reasoning", delta = reasoningDelta })
        end

        if delta.tool_calls then
            for _, call in ipairs(delta.tool_calls) do
                accumulateToolCall(call)
            end
        end
    end, client.provider)

    local finalToolCalls = #toolCalls > 0 and toolCalls or nil
    local result = {
        text = #text > 0 and table.concat(text) or nil,
        reasoning = #reasoning > 0 and table.concat(reasoning) or nil,
        finishReason = finishReason,
        toolCalls = finalToolCalls,
        usage = usage,
    }

    onEvent({ type = "done", finishReason = finishReason, usage = usage, text = result.text, toolCalls = finalToolCalls })
    return result
end

function adapter.image(client, request)
    local body = {
        model = request.model or client.imageModel or client.model,
        prompt = request.prompt,
        n = request.n,
        size = request.size,
        quality = request.quality,
        response_format = request.responseFormat,
    }
    for key, value in pairs(request.extra or {}) do
        body[key] = value
    end

    local data = transport.sendJson({
        url = client.baseUrl .. "/images/generations",
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    }, client.provider)

    local images = {}
    for _, item in ipairs(data.data or {}) do
        images[#images + 1] = { base64 = item.b64_json, url = item.url, revisedPrompt = item.revised_prompt }
    end

    return { images = images, raw = data }
end

function adapter.embed(client, request)
    local data = transport.sendJson({
        url = client.baseUrl .. "/embeddings",
        method = "POST",
        headers = headers(client),
        json = { model = request.model or client.embedModel or client.model, input = request.input },
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, client.provider)

    local vectors = {}
    for _, item in ipairs(data.data or {}) do
        vectors[#vectors + 1] = item.embedding
    end

    return { embeddings = vectors, usage = readUsage(data.usage), raw = data }
end

return adapter
