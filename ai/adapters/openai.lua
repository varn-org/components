-- the openai wire, which is also what every openai-compatible provider speaks, so the request and the response cross it unchanged
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

local function post(client, path, body, timeoutSeconds)
    return transport.sendJson({
        url = client.baseUrl .. path,
        method = "POST",
        headers = wire.headers(client),
        json = body,
        timeoutSeconds = timeoutSeconds or client.timeoutSeconds,
    }, client.provider)
end

function adapter.completion(client, request)
    return post(client, "/chat/completions", wire.body(client, request))
end

function adapter.streamCompletion(client, request, onChunk)
    local body = wire.body(client, request)
    body.stream = true
    body.stream_options = body.stream_options or { include_usage = true }

    local message = { role = "assistant" }
    local assembled = { id = nil, created = nil, model = nil, finish_reason = nil, usage = nil }

    transport.sse({
        url = client.baseUrl .. "/chat/completions",
        method = "POST",
        headers = wire.headers(client),
        json = body,
        timeoutSeconds = client.timeoutSeconds,
    }, function(_, payload)
        if payload == "[DONE]" then
            return
        end

        local chunk = json.decode(payload)
        assembled.id = assembled.id or chunk.id
        assembled.created = assembled.created or chunk.created
        assembled.model = assembled.model or chunk.model
        if chunk.usage then
            assembled.usage = chunk.usage
        end

        local choice = chunk.choices and chunk.choices[1]
        if choice then
            if choice.finish_reason then
                assembled.finish_reason = choice.finish_reason
            end
            wire.mergeDelta(message, choice.delta or {})
        end

        onChunk(chunk)
    end, client.provider)

    return wire.completionResponse({
        id = assembled.id,
        created = assembled.created,
        model = assembled.model or client.model,
        choices = { { index = 0, message = message, finish_reason = assembled.finish_reason } },
        usage = assembled.usage,
    })
end

function adapter.embedding(client, request)
    return post(client, "/embeddings", wire.body(client, request))
end

function adapter.imageGeneration(client, request)
    return post(client, "/images/generations", wire.body(client, request), client.timeoutSeconds or 120)
end

function adapter.moderation(client, request)
    return post(client, "/moderations", wire.body(client, request))
end

-- the qwen family serves reranking from a compatible-api sibling of the compatible-mode base its chat uses, and names the endpoint in the plural
local function rerankEndpoint(client)
    if client.provider == "dashscope" or client.provider == "qwencloud" or client.provider == "qwen_ai_platform" then
        return (client.baseUrl:gsub("compatible%-mode", "compatible-api")) .. "/reranks"
    end

    return client.baseUrl .. "/rerank"
end

function adapter.rerank(client, request)
    return transport.sendJson({
        url = rerankEndpoint(client),
        method = "POST",
        headers = wire.headers(client),
        json = wire.body(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.transcription(client, request)
    if type(request.file) ~= "string" then
        error("ai: transcription needs request.file as the audio bytes", 0)
    end

    local parts = {
        { name = "file", filename = request.file_name or "audio.mp3", contentType = request.content_type, data = request.file },
        { name = "model", value = client.model },
    }

    for key, value in pairs(request) do
        if not wire.isControlKey(key) and key ~= "file" and key ~= "file_name" and key ~= "content_type" then
            parts[#parts + 1] = { name = key, value = value }
        end
    end

    local body, contentType = wire.multipart(parts)
    local response = transport.send({
        url = client.baseUrl .. "/audio/transcriptions",
        method = "POST",
        headers = wire.headers(client, { ["Content-Type"] = contentType }),
        body = body,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.json()
end

-- uploads the jsonl a batch reads its requests from, returning the file object whose id the batch is created with
function adapter.fileCreate(client, request)
    if type(request.file) ~= "string" then
        error("ai: fileCreate needs request.file as the file contents", 0)
    end

    local body, contentType = wire.multipart({
        { name = "file", filename = request.file_name or "batch.jsonl", contentType = "application/jsonl", data = request.file },
        { name = "purpose", value = request.purpose or "batch" },
    })

    local response = transport.send({
        url = client.baseUrl .. "/files",
        method = "POST",
        headers = wire.headers(client, { ["Content-Type"] = contentType }),
        body = body,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.json()
end

function adapter.batchCreate(client, request)
    return post(client, "/batches", {
        input_file_id = request.input_file_id,
        endpoint = request.endpoint or "/v1/chat/completions",
        completion_window = request.completion_window or "24h",
        metadata = request.metadata,
    })
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
        url = client.baseUrl .. "/batches/" .. batchId(request),
        method = "GET",
        headers = wire.headers(client),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchCancel(client, request)
    return post(client, "/batches/" .. batchId(request) .. "/cancel", {})
end

function adapter.batchList(client, request)
    return transport.sendJson({
        url = client.baseUrl .. "/batches",
        method = "GET",
        headers = wire.headers(client),
        query = { limit = request.limit, after = request.after },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

-- the results arrive as the jsonl the batch wrote, so they are returned decoded one record per entry
function adapter.batchResults(client, request)
    local batch = adapter.batchRetrieve(client, request)
    local fileId = batch.output_file_id
    if not fileId then
        error(string.format("%s: batch %s has no output yet (status %s)", client.provider, batchId(request), tostring(batch.status)), 0)
    end

    local response = transport.send({
        url = string.format("%s/files/%s/content", client.baseUrl, fileId),
        method = "GET",
        headers = wire.headers(client),
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

-- returns the raw audio bytes, which is what the speech endpoint answers with rather than json
function adapter.speech(client, request)
    local response = transport.send({
        url = client.baseUrl .. "/audio/speech",
        method = "POST",
        headers = wire.headers(client),
        json = wire.body(client, request),
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.body
end

return adapter
