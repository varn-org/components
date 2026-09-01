-- ibm watsonx, whose chat wire already carries openai-shaped messages but authenticates with an iam token exchanged from the api key
local http = require("http")
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

-- the public cloud identity endpoint, which a cloud pak deployment replaces through iam_url or WATSONX_IAM_URL
local defaultIamUrl = "https://iam.cloud.ibm.com/identity/token"
local defaultVersion = "2024-03-14"

-- one exchanged token serves every later call until it expires, so it is cached against the key that bought it
local tokenCache = {}

local function bearerToken(client)
    if client.apiKey and client.apiKey:find("^Bearer ") then
        return client.apiKey:sub(8)
    end

    local token = os.getenv("WATSONX_TOKEN")
    if token then
        return token
    end

    if not client.apiKey then
        error("ai: watsonx needs WATSONX_API_KEY or a WATSONX_TOKEN", 0)
    end

    local cached = tokenCache[client.apiKey]
    if cached and cached.expiresAt > os.time() + 60 then
        return cached.value
    end

    local body = string.format(
        "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=%s",
        http.urlEncode(client.apiKey)
    )

    local data = transport.sendJson({
        url = client.iamUrl or os.getenv("WATSONX_IAM_URL") or defaultIamUrl,
        method = "POST",
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded", ["Accept"] = "application/json" },
        body = body,
        timeoutSeconds = client.timeoutSeconds,
    }, "watsonx iam")

    tokenCache[client.apiKey] = { value = data.access_token, expiresAt = os.time() + (data.expires_in or 3600) }
    return data.access_token
end

local function projectId(request)
    local id = request.project_id or os.getenv("WATSONX_PROJECT_ID")
    if not id then
        error("ai: watsonx needs project_id or WATSONX_PROJECT_ID", 0)
    end

    return id
end

local function buildBody(client, request)
    local body = wire.body(client, request)

    body.model = nil
    body.model_id = client.model
    body.project_id = projectId(request)

    return body
end

local function endpoint(client)
    return string.format("%s/ml/v1/text/chat?version=%s", client.baseUrl, client.apiVersion or defaultVersion)
end

function adapter.completion(client, request)
    return transport.sendJson({
        url = endpoint(client),
        method = "POST",
        headers = wire.headers({ apiKey = bearerToken(client), headers = client.headers }),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)
end

-- the streaming endpoint is a sibling of the chat one and already emits openai-shaped chunks
function adapter.streamCompletion(client, request, onChunk)
    local message = { role = "assistant" }
    local state = {}

    transport.sse({
        url = string.format("%s/ml/v1/text/chat_stream?version=%s", client.baseUrl, client.apiVersion or defaultVersion),
        method = "POST",
        headers = wire.headers({ apiKey = bearerToken(client), headers = client.headers }),
        json = buildBody(client, request),
        timeoutSeconds = client.timeoutSeconds,
    }, function(_, payload)
        if payload == "[DONE]" then
            return
        end

        local chunk = json.decode(payload)
        state.id = state.id or chunk.id
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
        model = client.model,
        choices = { { index = 0, message = message, finish_reason = state.finish_reason } },
        usage = state.usage,
    })
end

function adapter.embedding(client, request)
    local body = wire.body(client, request)
    body.model = nil
    body.model_id = client.model
    body.project_id = projectId(request)
    body.inputs = type(request.input) == "table" and request.input or { request.input }
    body.input = nil

    local data = transport.sendJson({
        url = string.format("%s/ml/v1/text/embeddings?version=%s", client.baseUrl, client.apiVersion or defaultVersion),
        method = "POST",
        headers = wire.headers({ apiKey = bearerToken(client), headers = client.headers }),
        json = body,
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    local items = {}
    for index, result in ipairs(data.results or {}) do
        items[#items + 1] = { object = "embedding", index = index - 1, embedding = result.embedding }
    end

    return { object = "list", data = items, model = client.model }
end

return adapter
