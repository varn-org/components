-- aws bedrock through the converse api, signed with signature version 4 and translated in both directions
local eventstream = require("ai.eventstream")
local json = require("json")
local sigv4 = require("ai.sigv4")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

local service = "bedrock"

local finishReasons = {
    end_turn = "stop",
    stop_sequence = "stop",
    max_tokens = "length",
    tool_use = "tool_calls",
    content_filtered = "content_filter",
    guardrail_intervened = "content_filter",
}

local function credentials(client)
    local accessKey = client.accessKeyId or os.getenv("AWS_ACCESS_KEY_ID")
    local secretKey = client.apiKey or os.getenv("AWS_SECRET_ACCESS_KEY")
    local region = client.region or os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")

    if not accessKey or not secretKey then
        error("ai: bedrock needs AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY", 0)
    end
    if not region then
        error("ai: bedrock needs aws_region_name or AWS_REGION", 0)
    end

    return accessKey, secretKey, region, client.sessionToken or os.getenv("AWS_SESSION_TOKEN")
end

local function contentBlocks(content)
    if type(content) == "string" then
        return { { text = content } }
    end

    local blocks = {}
    for _, part in ipairs(content or {}) do
        if part.type == "text" then
            blocks[#blocks + 1] = { text = part.text }
        elseif part.type == "image_url" then
            local format, data = part.image_url.url:match("^data:image/([%w]+);base64,(.+)$")
            if not format then
                error("ai: bedrock needs an inline base64 data url for an image", 0)
            end
            blocks[#blocks + 1] = { image = { format = format, source = { bytes = data } } }
        end
    end

    return blocks
end

-- converse keeps the system prompt beside the conversation and carries tool traffic as content blocks
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
                content = { { toolResult = { toolUseId = message.tool_call_id, content = { { text = message.content } } } } },
            }
        elseif message.role == "assistant" then
            local blocks = {}
            if message.content and message.content ~= "" then
                for _, block in ipairs(contentBlocks(message.content)) do
                    blocks[#blocks + 1] = block
                end
            end

            for _, call in ipairs(message.tool_calls or {}) do
                local fn = call["function"] or {}
                blocks[#blocks + 1] = {
                    toolUse = {
                        toolUseId = call.id,
                        name = fn.name,
                        input = fn.arguments and fn.arguments ~= "" and json.decode(fn.arguments) or {},
                    },
                }
            end

            turns[#turns + 1] = { role = "assistant", content = blocks }
        else
            turns[#turns + 1] = { role = "user", content = contentBlocks(message.content) }
        end
    end

    return (#system > 0 and system or nil), turns
end

local function wireToolConfig(request)
    if not request.tools then
        return nil
    end

    local specs = {}
    for _, tool in ipairs(request.tools) do
        local fn = tool["function"] or tool
        specs[#specs + 1] = {
            toolSpec = { name = fn.name, description = fn.description, inputSchema = { json = fn.parameters } },
        }
    end

    local config = { tools = specs }
    local choice = request.tool_choice

    if choice == "auto" then
        config.toolChoice = { auto = {} }
    elseif choice == "required" then
        config.toolChoice = { any = {} }
    elseif type(choice) == "table" and choice["function"] then
        config.toolChoice = { tool = { name = choice["function"].name } }
    end

    return config
end

local function buildBody(client, request)
    local system, messages = splitMessages(request.messages)

    return {
        messages = messages,
        system = system,
        inferenceConfig = {
            temperature = request.temperature,
            topP = request.top_p,
            maxTokens = request.max_tokens,
            stopSequences = type(request.stop) == "table" and request.stop or (request.stop and { request.stop }),
        },
        toolConfig = wireToolConfig(request),
    }
end

local function readUsage(usage)
    if not usage then
        return nil
    end

    return {
        prompt_tokens = usage.inputTokens,
        completion_tokens = usage.outputTokens,
        total_tokens = usage.totalTokens,
    }
end

local function readMessage(source)
    local message = { role = "assistant" }
    local text = {}

    for _, block in ipairs(source and source.content or {}) do
        if block.text then
            text[#text + 1] = block.text
        elseif block.reasoningContent then
            local reasoning = block.reasoningContent.reasoningText
            message.reasoning_content = (message.reasoning_content or "") .. (reasoning and reasoning.text or "")
        elseif block.toolUse then
            message.tool_calls = message.tool_calls or {}
            message.tool_calls[#message.tool_calls + 1] = {
                index = #message.tool_calls,
                id = block.toolUse.toolUseId,
                type = "function",
                ["function"] = { name = block.toolUse.name, arguments = json.encode(block.toolUse.input or {}) },
            }
        end
    end

    message.content = #text > 0 and table.concat(text) or nil
    return message
end

-- the runtime host is regional and the model id travels in the path, so the endpoint is signed per call
local function signedOptions(client, path, body)
    local accessKey, secretKey, region, sessionToken = credentials(client)
    local host = string.format("bedrock-runtime.%s.amazonaws.com", region)
    local payload = json.encode(body)

    local headers = sigv4.headers({
        method = "POST",
        host = host,
        path = path,
        body = payload,
        service = service,
        region = region,
        accessKey = accessKey,
        secretKey = secretKey,
        sessionToken = sessionToken,
    })

    for key, value in pairs(client.headers or {}) do
        headers[key] = value
    end

    return {
        url = (client.baseUrl or ("https://" .. host)) .. path,
        method = "POST",
        headers = headers,
        body = payload,
        timeoutSeconds = client.timeoutSeconds,
    }
end

function adapter.completion(client, request)
    local body = buildBody(client, request)
    local data = transport.sendJson(signedOptions(client, "/model/" .. client.model .. "/converse", body), client.provider)


    return wire.completionResponse({
        model = client.model,
        choices = {
            {
                index = 0,
                message = readMessage(data.output and data.output.message),
                finish_reason = finishReasons[data.stopReason] or data.stopReason,
            },
        },
        usage = readUsage(data.usage),
    })
end

-- converse-stream answers with the aws binary event protocol rather than server-sent events, so the frames are decoded before their json is read
function adapter.streamCompletion(client, request, onChunk)
    local body = buildBody(client, request)
    local options = signedOptions(client, "/model/" .. client.model .. "/converse-stream", body)

    local message = { role = "assistant" }
    local blocks = {}
    local state = {}
    local buffer = ""

    local function emit(delta, finishReason)
        onChunk(wire.chunk({ model = client.model, delta = delta, finish_reason = finishReason }))
    end

    local function onEvent(headers, payload)
        local eventType = headers[":event-type"]

        if headers[":message-type"] == "exception" or eventType == "internalServerException" or eventType == "modelStreamErrorException" then
            error(string.format("%s: %s %s", client.provider, tostring(eventType), payload), 0)
        end

        local event = json.decode(payload)

        if eventType == "messageStart" then
            emit({ role = "assistant" })
            return
        end

        if eventType == "contentBlockStart" then
            local start = event.start or {}
            if start.toolUse then
                message.tool_calls = message.tool_calls or {}
                local index = #message.tool_calls
                blocks[event.contentBlockIndex or 0] = index + 1
                message.tool_calls[index + 1] = {
                    index = index,
                    id = start.toolUse.toolUseId,
                    type = "function",
                    ["function"] = { name = start.toolUse.name, arguments = "" },
                }
                emit({ tool_calls = { { index = index, id = start.toolUse.toolUseId, type = "function", ["function"] = { name = start.toolUse.name, arguments = "" } } } })
            end
            return
        end

        if eventType == "contentBlockDelta" then
            local delta = event.delta or {}

            if delta.text then
                message.content = (message.content or "") .. delta.text
                emit({ content = delta.text })
            elseif delta.reasoningContent and delta.reasoningContent.text then
                message.reasoning_content = (message.reasoning_content or "") .. delta.reasoningContent.text
                emit({ reasoning_content = delta.reasoningContent.text })
            elseif delta.toolUse and delta.toolUse.input then
                local slot = blocks[event.contentBlockIndex or 0]
                if slot then
                    local call = message.tool_calls[slot]
                    call["function"].arguments = call["function"].arguments .. delta.toolUse.input
                    emit({ tool_calls = { { index = call.index, ["function"] = { arguments = delta.toolUse.input } } } })
                end
            end
            return
        end

        if eventType == "messageStop" then
            state.finish_reason = finishReasons[event.stopReason] or event.stopReason
            emit({}, state.finish_reason)
            return
        end

        if eventType == "metadata" then
            state.usage = readUsage(event.usage)
        end
    end

    transport.raw(options, function(chunk)
        buffer = eventstream.consume(buffer .. chunk, onEvent)
    end, client.provider)

    return wire.completionResponse({
        model = client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

-- the two embedding families on bedrock name their input differently, and the model id says which one this is
local function embeddingBody(model, text, request)
    if model:find("^cohere%.") then
        return { texts = { text }, input_type = request.input_type or "search_document" }
    end

    return { inputText = text, dimensions = request.dimensions }
end

local function readEmbedding(model, data)
    if model:find("^cohere%.") then
        return data.embeddings and data.embeddings[1]
    end

    return data.embedding
end

-- invoke handles one input at a time, so a list is sent as one signed call per entry
function adapter.embedding(client, request)
    local inputs = type(request.input) == "table" and request.input or { request.input }
    local items = {}
    local total = 0

    for index, text in ipairs(inputs) do
        local body = embeddingBody(client.model, text, request)
        local data = transport.sendJson(signedOptions(client, "/model/" .. client.model .. "/invoke", body), client.provider)

        items[#items + 1] = { object = "embedding", index = index - 1, embedding = readEmbedding(client.model, data) }
        total = total + (data.inputTextTokenCount or 0)
    end

    return {
        object = "list",
        data = items,
        model = client.model,
        usage = { prompt_tokens = total, total_tokens = total },
    }
end

function adapter.rerank(client, request)
    local documents = {}
    for _, document in ipairs(request.documents or {}) do
        local text = type(document) == "table" and (document.text or document.content) or document
        documents[#documents + 1] = { type = "TEXT", textDocument = { text = text } }
    end

    local region = client.region or os.getenv("AWS_REGION") or os.getenv("AWS_DEFAULT_REGION")
    local body = {
        queries = { { type = "TEXT", textQuery = { text = request.query } } },
        sources = documents,
        rerankingConfiguration = {
            type = "BEDROCK_RERANKING_MODEL",
            bedrockRerankingConfiguration = {
                numberOfResults = request.top_n or #documents,
                modelConfiguration = {
                    modelArn = string.format("arn:aws:bedrock:%s::foundation-model/%s", tostring(region), client.model),
                },
            },
        },
    }

    local data = transport.sendJson(signedOptions(client, "/rerank", body), client.provider)

    local results = {}
    for _, result in ipairs(data.results or {}) do
        results[#results + 1] = { index = result.index, relevance_score = result.relevanceScore }
    end

    return { object = "rerank", model = client.model, results = results }
end

return adapter
