-- google gemini adapter over the generative language api covering text, vision, function calling, and native image generation
local json = require("json")
local transport = require("ai.http")

local adapter = {}

local function headers(client)
    local out = { ["Content-Type"] = "application/json" }
    if client.apiKey then
        out["x-goog-api-key"] = client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

local roleMap = { user = "user", assistant = "model" }

local function contentParts(content)
    if type(content) == "string" then
        return { { text = content } }
    end

    local parts = {}
    for _, part in ipairs(content) do
        if part.type == "text" then
            parts[#parts + 1] = { text = part.text }
        elseif part.type == "image" then
            parts[#parts + 1] = { inlineData = { mimeType = part.mediaType or "image/png", data = part.base64 } }
        end
    end

    return parts
end

-- folds the normalized transcript into gemini contents, lifting system text to systemInstruction and turning tool calls and results into functionCall and functionResponse parts
local function buildContents(request)
    local systemParts = {}
    if request.system then
        systemParts[#systemParts + 1] = { text = request.system }
    end

    local contents = {}
    for _, message in ipairs(request.messages or {}) do
        if message.role == "system" then
            systemParts[#systemParts + 1] = { text = message.content }
        elseif message.role == "tool" then
            local response = type(message.content) == "table" and message.content or { result = message.content }
            contents[#contents + 1] = { role = "user", parts = { { functionResponse = { name = message.name, response = response } } } }
        elseif message.role == "assistant" and message.toolCalls then
            local parts = {}
            if type(message.content) == "string" and message.content ~= "" then
                parts[#parts + 1] = { text = message.content }
            end
            for _, call in ipairs(message.toolCalls) do
                parts[#parts + 1] = { functionCall = { name = call.name, args = json.decode(call.arguments) } }
            end
            contents[#contents + 1] = { role = "model", parts = parts }
        else
            contents[#contents + 1] = { role = roleMap[message.role] or "user", parts = contentParts(message.content) }
        end
    end

    local systemInstruction = #systemParts > 0 and { parts = systemParts } or nil
    return contents, systemInstruction
end

local choiceModeMap = { auto = "AUTO", required = "ANY", none = "NONE" }

local function buildTools(request)
    if not request.tools then
        return nil, nil
    end

    local declarations = {}
    for _, tool in ipairs(request.tools) do
        declarations[#declarations + 1] = { name = tool.name, description = tool.description, parameters = tool.parameters }
    end

    local toolConfig
    if type(request.toolChoice) == "string" and choiceModeMap[request.toolChoice] then
        toolConfig = { functionCallingConfig = { mode = choiceModeMap[request.toolChoice] } }
    end

    return { { functionDeclarations = declarations } }, toolConfig
end

local function buildGenerationConfig(request)
    local config = {
        temperature = request.temperature,
        maxOutputTokens = request.maxTokens,
        topP = request.topP,
        stopSequences = request.stop,
    }

    if request.responseFormat == "json" or (type(request.responseFormat) == "table" and request.responseFormat.json) then
        config.responseMimeType = "application/json"
        if type(request.responseFormat) == "table" then
            config.responseSchema = request.responseFormat.schema
        end
    end

    for key, value in pairs(request.generationConfig or {}) do
        config[key] = value
    end

    return config
end

local function buildBody(request)
    local contents, systemInstruction = buildContents(request)
    local tools, toolConfig = buildTools(request)

    local body = {
        contents = contents,
        systemInstruction = systemInstruction,
        generationConfig = buildGenerationConfig(request),
        tools = tools,
        toolConfig = toolConfig,
    }

    for key, value in pairs(request.extra or {}) do
        body[key] = value
    end

    return body
end

local function readUsage(meta)
    if not meta then
        return nil
    end

    return {
        inputTokens = meta.promptTokenCount,
        outputTokens = meta.candidatesTokenCount,
        totalTokens = meta.totalTokenCount,
    }
end

-- pulls text, tool calls, and inline images out of a candidate's parts
local function collectParts(parts, text, toolCalls, images)
    for _, part in ipairs(parts or {}) do
        if part.text then
            text[#text + 1] = part.text
        elseif part.functionCall then
            toolCalls[#toolCalls + 1] = { name = part.functionCall.name, arguments = json.encode(part.functionCall.args or {}) }
        elseif part.inlineData and images then
            images[#images + 1] = { base64 = part.inlineData.data, mediaType = part.inlineData.mimeType }
        end
    end
end

local function endpoint(client, request, method, query)
    local model = request.model or client.model
    return string.format("%s/v1beta/models/%s:%s%s", client.baseUrl, model, method, query or "")
end

function adapter.generate(client, request)
    local data = transport.sendJson({
        url = endpoint(client, request, "generateContent"),
        method = "POST",
        headers = headers(client),
        json = buildBody(request),
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, client.provider)

    local candidate = data.candidates and data.candidates[1] or {}
    local text = {}
    local toolCalls = {}
    collectParts(candidate.content and candidate.content.parts, text, toolCalls, nil)

    return {
        text = #text > 0 and table.concat(text) or nil,
        finishReason = candidate.finishReason,
        toolCalls = #toolCalls > 0 and toolCalls or nil,
        usage = readUsage(data.usageMetadata),
        raw = data,
    }
end

function adapter.stream(client, request, onEvent)
    local text = {}
    local toolCalls = {}
    local finishReason
    local usage

    transport.sse({
        url = endpoint(client, request, "streamGenerateContent", "?alt=sse"),
        method = "POST",
        headers = headers(client),
        json = buildBody(request),
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds,
    }, function(_, payload)
        local chunk = json.decode(payload)
        if chunk.usageMetadata then
            usage = readUsage(chunk.usageMetadata)
        end

        local candidate = chunk.candidates and chunk.candidates[1]
        if not candidate then
            return
        end

        if candidate.finishReason then
            finishReason = candidate.finishReason
        end

        for _, part in ipairs(candidate.content and candidate.content.parts or {}) do
            if part.text then
                text[#text + 1] = part.text
                onEvent({ type = "text", delta = part.text })
            elseif part.functionCall then
                toolCalls[#toolCalls + 1] = { name = part.functionCall.name, arguments = json.encode(part.functionCall.args or {}) }
            end
        end
    end, client.provider)

    local result = {
        text = #text > 0 and table.concat(text) or nil,
        finishReason = finishReason,
        toolCalls = #toolCalls > 0 and toolCalls or nil,
        usage = usage,
    }

    onEvent({ type = "done", finishReason = finishReason, usage = usage, text = result.text, toolCalls = result.toolCalls })
    return result
end

function adapter.image(client, request)
    local model = request.model or client.imageModel or client.model
    local body = {
        contents = { { role = "user", parts = { { text = request.prompt } } } },
        generationConfig = { responseModalities = request.responseModalities or { "TEXT", "IMAGE" }, imageConfig = request.imageConfig },
    }
    for key, value in pairs(request.extra or {}) do
        body[key] = value
    end

    local data = transport.sendJson({
        url = string.format("%s/v1beta/models/%s:generateContent", client.baseUrl, model),
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    }, client.provider)

    local candidate = data.candidates and data.candidates[1] or {}
    local images = {}
    collectParts(candidate.content and candidate.content.parts, {}, {}, images)

    return { images = images, raw = data }
end

return adapter
