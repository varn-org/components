-- azure openai, which speaks the openai wire under a deployment-scoped path with the key in its own header
local transport = require("ai.http")
local wire = require("ai.wire")
local json = require("json")

local adapter = {}

local defaultApiVersion = "2024-10-21"

-- the model names the deployment on azure, and the api version is a required query parameter
local function endpoint(client, path)
    return string.format(
        "%s/openai/deployments/%s%s?api-version=%s",
        client.baseUrl,
        client.model,
        path,
        client.apiVersion or defaultApiVersion
    )
end

local function headers(client, extra)
    local out = { ["Content-Type"] = "application/json" }
    if client.apiKey then
        out["api-key"] = client.apiKey
    end

    for key, value in pairs(extra or {}) do
        out[key] = value
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- the deployment already selects the model, so the body carries the request without it
local function buildBody(client, request)
    local body = wire.body(client, request)
    body.model = nil
    return body
end

function adapter.completion(client, request)
    return transport.sendJson({
        url = endpoint(client, "/chat/completions"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.streamCompletion(client, request, onChunk)
    local body = buildBody(client, request)
    body.stream = true
    body.stream_options = body.stream_options or { include_usage = true }

    local message = { role = "assistant" }
    local state = {}

    transport.sse({
        url = endpoint(client, "/chat/completions"),
        method = "POST",
        headers = headers(client),
        json = body,
        timeoutSeconds = client.timeoutSeconds,
    }, function(_, payload)
        if payload == "[DONE]" then
            return
        end

        local chunk = json.decode(payload)
        state.id = state.id or chunk.id
        state.model = state.model or chunk.model
        if chunk.usage then
            state.usage = chunk.usage
        end

        local choice = chunk.choices and chunk.choices[1]
        if choice then
            if choice.finish_reason then
                state.finish_reason = choice.finish_reason
            end
            wire.mergeDelta(message, choice.delta or {})
        end

        onChunk(chunk)
    end, client.provider)

    return wire.completionResponse({
        id = state.id,
        model = state.model or client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

function adapter.embedding(client, request)
    return transport.sendJson({
        url = endpoint(client, "/embeddings"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.imageGeneration(client, request)
    return transport.sendJson({
        url = endpoint(client, "/images/generations"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds or 120,
    }, client.provider)
end

function adapter.moderation(client, request)
    return transport.sendJson({
        url = endpoint(client, "/moderations"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.transcription(client, request)
    if type(request.file) ~= "string" then
        error("ai: transcription needs request.file as the audio bytes", 0)
    end

    local parts = {
        { name = "file", filename = request.file_name or "audio.mp3", contentType = request.content_type, data = request.file },
    }

    for key, value in pairs(request) do
        if not wire.isControlKey(key) and key ~= "file" and key ~= "file_name" and key ~= "content_type" then
            parts[#parts + 1] = { name = key, value = value }
        end
    end

    local body, contentType = wire.multipart(parts)
    local response = transport.send({
        url = endpoint(client, "/audio/transcriptions"),
        method = "POST",
        headers = headers(client, { ["Content-Type"] = contentType }),
        body = body,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.json()
end

-- returns the raw audio bytes, which is what the speech endpoint answers with rather than json
function adapter.speech(client, request)
    local response = transport.send({
        url = endpoint(client, "/audio/speech"),
        method = "POST",
        headers = headers(client),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.body
end

-- batches and their input files sit beside the deployments rather than under one, so they address the account endpoint
local function accountEndpoint(client, path)
    return string.format("%s/openai%s?api-version=%s", client.baseUrl, path, client.apiVersion or defaultApiVersion)
end

function adapter.fileCreate(client, request)
    if type(request.file) ~= "string" then
        error("ai: fileCreate needs request.file as the file contents", 0)
    end

    local body, contentType = wire.multipart({
        { name = "file", filename = request.file_name or "batch.jsonl", contentType = "application/jsonl", data = request.file },
        { name = "purpose", value = request.purpose or "batch" },
    })

    local response = transport.send({
        url = accountEndpoint(client, "/files"),
        method = "POST",
        headers = headers(client, { ["Content-Type"] = contentType }),
        body = body,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.json()
end

local function batchId(request)
    local id = request.batch_id
    if not id then
        error("ai: this call needs batch_id", 0)
    end

    return id
end

function adapter.batchCreate(client, request)
    return transport.sendJson({
        url = accountEndpoint(client, "/batches"),
        method = "POST",
        headers = headers(client),
        json = {
            input_file_id = request.input_file_id,
            endpoint = request.endpoint or "/chat/completions",
            completion_window = request.completion_window or "24h",
            metadata = request.metadata,
        },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchRetrieve(client, request)
    return transport.sendJson({
        url = accountEndpoint(client, "/batches/" .. batchId(request)),
        method = "GET",
        headers = headers(client),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchCancel(client, request)
    return transport.sendJson({
        url = accountEndpoint(client, "/batches/" .. batchId(request) .. "/cancel"),
        method = "POST",
        headers = headers(client),
        json = {},
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchList(client, request)
    return transport.sendJson({
        url = accountEndpoint(client, "/batches"),
        method = "GET",
        headers = headers(client),
        query = { limit = request.limit, after = request.after },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

function adapter.batchResults(client, request)
    local batch = adapter.batchRetrieve(client, request)
    local fileId = batch.output_file_id
    if not fileId then
        error(string.format("%s: batch %s has no output yet (status %s)", client.provider, batchId(request), tostring(batch.status)), 0)
    end

    local response = transport.send({
        url = accountEndpoint(client, "/files/" .. fileId .. "/content"),
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

return adapter
