-- the google generative language api, serving both ai studio and vertex ai, translated in both directions so callers keep writing openai-shaped requests
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

-- gemini spells its stop reasons in caps and a caller branching on finish_reason expects the openai spelling
local finishReasons = {
    STOP = "stop",
    MAX_TOKENS = "length",
    SAFETY = "content_filter",
    RECITATION = "content_filter",
    PROHIBITED_CONTENT = "content_filter",
    BLOCKLIST = "content_filter",
    SPII = "content_filter",
    MALFORMED_FUNCTION_CALL = "tool_calls",
}

local toolModes = {
    auto = "AUTO",
    required = "ANY",
    none = "NONE",
}

-- ai studio authenticates with a key on the url while vertex takes a bearer token and addresses a project
local function endpoint(client, method, query)
    if client.provider == "vertex_ai" or client.provider == "vertex_ai_beta" then
        if not client.project or not client.location then
            error("ai: vertex_ai needs vertex_project and vertex_location", 0)
        end

        local base = client.baseUrl or string.format("https://%s-aiplatform.googleapis.com", client.location)

        return string.format(
            "%s/v1/projects/%s/locations/%s/publishers/google/models/%s:%s%s",
            base,
            client.project,
            client.location,
            client.model,
            method,
            query or ""
        )
    end

    return string.format("%s/v1beta/models/%s:%s%s", client.baseUrl, client.model, method, query or "")
end

local function headers(client)
    local out = { ["Content-Type"] = "application/json" }

    if client.provider == "vertex_ai" or client.provider == "vertex_ai_beta" then
        if client.apiKey then
            out["Authorization"] = "Bearer " .. client.apiKey
        end
    elseif client.apiKey then
        out["x-goog-api-key"] = client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

local function inlineData(url)
    local mimeType, data = url:match("^data:([%w%-%./+]+);base64,(.+)$")
    if mimeType then
        return { inline_data = { mime_type = mimeType, data = data } }
    end

    return { file_data = { file_uri = url } }
end

local function contentParts(content)
    if type(content) == "string" then
        return { { text = content } }
    end

    local parts = {}
    for _, part in ipairs(content or {}) do
        if part.type == "text" then
            parts[#parts + 1] = { text = part.text }
        elseif part.type == "image_url" then
            parts[#parts + 1] = inlineData(part.image_url.url)
        end
    end

    return parts
end

-- gemini calls the assistant "model" and carries tool calls and their results as parts rather than separate roles
local function splitMessages(messages)
    local system = {}
    local contents = {}
    local callNames = {}

    for _, message in ipairs(messages or {}) do
        if message.role == "system" then
            for _, part in ipairs(contentParts(message.content)) do
                system[#system + 1] = part
            end
        elseif message.role == "assistant" then
            local parts = {}
            if message.content and message.content ~= "" then
                for _, part in ipairs(contentParts(message.content)) do
                    parts[#parts + 1] = part
                end
            end

            for _, call in ipairs(message.tool_calls or {}) do
                local fn = call["function"] or {}
                callNames[call.id] = fn.name
                local arguments = fn.arguments
                parts[#parts + 1] = {
                    functionCall = { name = fn.name, args = arguments and arguments ~= "" and json.decode(arguments) or {} },
                }
            end

            contents[#contents + 1] = { role = "model", parts = parts }
        elseif message.role == "tool" then
            contents[#contents + 1] = {
                role = "user",
                parts = {
                    {
                        functionResponse = {
                            name = callNames[message.tool_call_id] or message.name or message.tool_call_id,
                            response = { content = message.content },
                        },
                    },
                },
            }
        else
            contents[#contents + 1] = { role = "user", parts = contentParts(message.content) }
        end
    end

    return (#system > 0 and { parts = system } or nil), contents
end

local function wireTools(tools)
    if not tools then
        return nil
    end

    local declarations = {}
    for _, tool in ipairs(tools) do
        local fn = tool["function"] or tool
        declarations[#declarations + 1] = { name = fn.name, description = fn.description, parameters = fn.parameters }
    end

    return { { functionDeclarations = declarations } }
end

local function wireToolConfig(choice)
    if choice == nil then
        return nil
    end

    local mode = type(choice) == "string" and toolModes[choice]
    if mode then
        return { functionCallingConfig = { mode = mode } }
    end

    local fn = type(choice) == "table" and choice["function"]
    if fn then
        return { functionCallingConfig = { mode = "ANY", allowedFunctionNames = { fn.name } } }
    end

    error("ai: gemini does not understand tool_choice " .. tostring(choice), 0)
end

local function buildBody(client, request)
    local systemInstruction, contents = splitMessages(request.messages)

    local generationConfig = {
        temperature = request.temperature,
        topP = request.top_p,
        maxOutputTokens = request.max_tokens or request.max_completion_tokens,
        stopSequences = type(request.stop) == "table" and request.stop or (request.stop and { request.stop }),
        candidateCount = request.n,
        seed = request.seed,
    }

    if request.response_format and request.response_format.type == "json_object" then
        generationConfig.responseMimeType = "application/json"
    elseif request.response_format and request.response_format.type == "json_schema" then
        generationConfig.responseMimeType = "application/json"
        generationConfig.responseSchema = request.response_format.json_schema and request.response_format.json_schema.schema
    end

    return {
        contents = contents,
        systemInstruction = systemInstruction,
        generationConfig = generationConfig,
        tools = wireTools(request.tools),
        toolConfig = wireToolConfig(request.tool_choice),
        safetySettings = request.safety_settings,
    }
end

local function readUsage(usage)
    if not usage then
        return nil
    end

    return {
        prompt_tokens = usage.promptTokenCount,
        completion_tokens = usage.candidatesTokenCount,
        total_tokens = usage.totalTokenCount,
    }
end

-- gemini gives a function call no id, so one is synthesized from its position to keep the openai round trip addressable
local function readMessage(candidate, counter)
    local message = { role = "assistant" }
    local text = {}

    for _, part in ipairs(candidate and candidate.content and candidate.content.parts or {}) do
        if part.text then
            if part.thought then
                message.reasoning_content = (message.reasoning_content or "") .. part.text
            else
                text[#text + 1] = part.text
            end
        elseif part.functionCall then
            message.tool_calls = message.tool_calls or {}
            counter.value = counter.value + 1
            message.tool_calls[#message.tool_calls + 1] = {
                index = #message.tool_calls,
                id = string.format("call_%s_%d", part.functionCall.name, counter.value),
                type = "function",
                ["function"] = { name = part.functionCall.name, arguments = json.encode(part.functionCall.args or {}) },
            }
        end
    end

    message.content = #text > 0 and table.concat(text) or nil
    return message
end

function adapter.completion(client, request)
    local data = transport.sendJson({
        url = endpoint(client, "generateContent"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    local candidate = data.candidates and data.candidates[1]

    return wire.completionResponse({
        id = data.responseId,
        model = data.modelVersion or client.model,
        choices = {
            {
                index = 0,
                message = readMessage(candidate, { value = 0 }),
                finish_reason = finishReasons[candidate and candidate.finishReason] or (candidate and candidate.finishReason),
            },
        },
        usage = readUsage(data.usageMetadata),
    })
end

function adapter.streamCompletion(client, request, onChunk)
    local message = { role = "assistant" }
    local counter = { value = 0 }
    local state = { id = nil, model = nil, finish_reason = nil, usage = nil }
    local first = true

    transport.sse({
        url = endpoint(client, "streamGenerateContent", "?alt=sse"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, function(_, payload)
        local event = json.decode(payload)
        state.id = state.id or event.responseId
        state.model = state.model or event.modelVersion
        if event.usageMetadata then
            state.usage = readUsage(event.usageMetadata)
        end

        local candidate = event.candidates and event.candidates[1]
        if not candidate then
            return
        end

        if candidate.finishReason then
            state.finish_reason = finishReasons[candidate.finishReason] or candidate.finishReason
        end

        local piece = readMessage(candidate, counter)
        local delta = {}

        if first then
            delta.role = "assistant"
            first = false
        end

        if piece.content then
            message.content = (message.content or "") .. piece.content
            delta.content = piece.content
        end

        if piece.reasoning_content then
            message.reasoning_content = (message.reasoning_content or "") .. piece.reasoning_content
            delta.reasoning_content = piece.reasoning_content
        end

        for _, call in ipairs(piece.tool_calls or {}) do
            message.tool_calls = message.tool_calls or {}
            call.index = #message.tool_calls
            message.tool_calls[#message.tool_calls + 1] = call
            delta.tool_calls = delta.tool_calls or {}
            delta.tool_calls[#delta.tool_calls + 1] = call
        end

        onChunk(wire.chunk({
            id = state.id,
            model = state.model or client.model,
            delta = delta,
            finish_reason = candidate.finishReason and state.finish_reason,
        }))
    end, client.provider)

    return wire.completionResponse({
        id = state.id,
        model = state.model or client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

function adapter.embedding(client, request)
    local inputs = type(request.input) == "table" and request.input or { request.input }

    local requests = {}
    for _, text in ipairs(inputs) do
        requests[#requests + 1] = {
            model = "models/" .. client.model,
            content = { parts = { { text = text } } },
            outputDimensionality = request.dimensions,
        }
    end

    local data = transport.sendJson({
        url = endpoint(client, "batchEmbedContents"),
        method = "POST",
        headers = headers(client),
        json = { requests = requests },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    local items = {}
    for index, embedding in ipairs(data.embeddings or {}) do
        items[#items + 1] = { object = "embedding", index = index - 1, embedding = embedding.values }
    end

    return { object = "list", data = items, model = client.model }
end

-- imagen answers a predict call rather than generateContent, and returns its images inline as base64
function adapter.imageGeneration(client, request)
    local data = transport.sendJson({
        url = endpoint(client, "predict"),
        method = "POST",
        headers = headers(client),
        json = {
            instances = { { prompt = request.prompt } },
            parameters = {
                sampleCount = request.n or 1,
                aspectRatio = request.aspect_ratio,
                seed = request.seed,
                negativePrompt = request.negative_prompt,
            },
        },
        timeoutSeconds = client.timeoutSeconds or 120,
    }, client.provider)

    local images = {}
    for _, prediction in ipairs(data.predictions or {}) do
        images[#images + 1] = { b64_json = prediction.bytesBase64Encoded }
    end

    return { created = os.time(), data = images }
end

return adapter
