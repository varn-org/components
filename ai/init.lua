-- one client for every supported provider, where a call names the model as "provider/model" and carries an openai-shaped request, and every call yields on the event loop so it must run inside an async coroutine (async.run/async.spawn)
local crypto = require("crypto")
local fs = require("fs")
local http = require("http")

local capabilities = require("ai.capabilities")
local providers = require("ai.providers")
local shapes = require("ai.shapes")

local ai = {}

-- adapters are required lazily so loading ai never forces a wire adapter a program does not use
local adapterCache = {}

local function loadAdapter(name)
    local adapter = adapterCache[name]
    if not adapter then
        adapter = require("ai.adapters." .. name)
        adapterCache[name] = adapter
    end

    return adapter
end

-- splits "provider/model" into its parts, reading a bare model name as an openai model
local function splitModel(model)
    if type(model) ~= "string" or model == "" then
        error("ai: request.model is required", 0)
    end

    local slug, rest = model:match("^([%w_%-%.]+)/(.+)$")
    if slug and providers[slug] then
        return slug, rest
    end

    return "openai", model
end

local function readEnv(names)
    for _, name in ipairs(names) do
        local value = os.getenv(name)
        if value and value ~= "" then
            return value
        end
    end
end

-- resolves the provider profile, credentials and endpoint for one request
local function resolve(request)
    local slug, model = splitModel(request.model)
    local profile = providers[slug]

    local baseUrl = request.api_base or os.getenv(profile.baseUrlEnv) or profile.baseUrl
    if not baseUrl and not profile.derivesEndpoint then
        error(string.format("ai: provider %s has no default endpoint, pass api_base or set %s", slug, profile.baseUrlEnv), 0)
    end

    return {
        provider = slug,
        model = model,
        baseUrl = baseUrl and (baseUrl:gsub("/+$", "")) or nil,
        apiKey = request.api_key or readEnv(profile.apiKeyEnv),
        apiVersion = request.api_version,
        headers = request.extra_headers,
        timeoutSeconds = request.timeout,
        region = request.aws_region_name,
        accessKeyId = request.aws_access_key_id,
        sessionToken = request.aws_session_token,
        project = request.vertex_project,
        location = request.vertex_location,
        iamUrl = request.iam_url,
        adapterName = profile.adapter,
        adapter = loadAdapter(profile.adapter),
    }
end

-- the capability a call needs, which is one entry per endpoint family rather than per function
local needs = {
    embedding = "embedding",
    imageGeneration = "imageGeneration",
    transcription = "transcription",
    speech = "speech",
    moderation = "moderation",
    rerank = "rerank",
    batchCreate = "batch",
    batchRetrieve = "batch",
    batchCancel = "batch",
    batchList = "batch",
    batchResults = "batch",
    fileCreate = "batch",
}

-- a specialised endpoint is refused up front when the provider does not serve it, so the caller sees why instead of a transport error
local function call(request, method, label)
    local client = resolve(request)
    local handler = client.adapter[method]

    if not handler then
        error(string.format("ai: provider %s does not serve %s", client.provider, label), 0)
    end

    -- one adapter serves many providers, so a specialised endpoint is checked against what this provider declares
    local needed = needs[method]
    if needed and client.adapterName == "openai" and not capabilities.serves(client.provider, needed) then
        error(string.format("ai: provider %s does not serve %s", client.provider, label), 0)
    end

    return handler(client, request)
end

-- performs a chat completion, streaming openai-shaped chunks into onChunk when one is given and returning the assembled response either way
function ai.completion(request, onChunk)
    if not onChunk then
        return call(request, "completion", "completion")
    end

    local client = resolve(request)
    if not client.adapter.streamCompletion then
        error(string.format("ai: provider %s does not support streaming", client.provider), 0)
    end

    return client.adapter.streamCompletion(client, request, onChunk)
end

-- the message surface, where the conversation carries content blocks and a system prompt of its own
function ai.messages(request, onChunk)
    local chat = shapes.messagesToChat(request)

    if not onChunk then
        return shapes.chatToMessages(ai.completion(chat))
    end

    return shapes.chatToMessages(ai.completion(chat, onChunk))
end

-- the response surface, where a single input replaces the conversation and the reply is a list of output items
function ai.responses(request, onChunk)
    local chat = shapes.responsesToChat(request)

    if not onChunk then
        return shapes.chatToResponses(ai.completion(chat))
    end

    return shapes.chatToResponses(ai.completion(chat, onChunk))
end

function ai.embedding(request)
    return call(request, "embedding", "embeddings")
end

function ai.imageGeneration(request)
    return call(request, "imageGeneration", "image generation")
end

function ai.transcription(request)
    return call(request, "transcription", "audio transcription")
end

function ai.speech(request)
    return call(request, "speech", "audio speech")
end

function ai.moderation(request)
    return call(request, "moderation", "moderations")
end

function ai.rerank(request)
    return call(request, "rerank", "rerank")
end

-- batches run a set of requests offline, so they are created, then polled, and their results fetched when the job reports itself complete
function ai.batchCreate(request)
    return call(request, "batchCreate", "batches")
end

function ai.batchRetrieve(request)
    return call(request, "batchRetrieve", "batches")
end

function ai.batchCancel(request)
    return call(request, "batchCancel", "batches")
end

function ai.batchList(request)
    return call(request, "batchList", "batches")
end

function ai.batchResults(request)
    return call(request, "batchResults", "batches")
end

-- uploading the input file is the first half of creating a batch on a provider that takes one
function ai.fileCreate(request)
    return call(request, "fileCreate", "file upload")
end

-- the provider slugs this client can address, sorted for a stable listing
function ai.providers()
    local names = {}
    for slug in pairs(providers) do
        names[#names + 1] = slug
    end

    table.sort(names)
    return names
end

-- writes an image returned by imageGeneration to a file, decoding its base64 or downloading its url
function ai.saveImage(image, path)
    assert(image, "ai.saveImage: no image given")

    local bytes
    if image.b64_json then
        bytes = crypto.base64Decode(image.b64_json)
    elseif image.url then
        local response, err = http.client.get(image.url):await()
        if err then
            error("ai.saveImage: download failed: " .. tostring(err), 0)
        end
        if not response.ok then
            error("ai.saveImage: download failed with http " .. response.status, 0)
        end
        bytes = response.body
    else
        error("ai.saveImage: image has neither b64_json nor url", 0)
    end

    fs.writeFile(path, bytes):await()
end

-- writes the raw audio bytes returned by speech to a file
function ai.saveAudio(bytes, path)
    fs.writeFile(path, bytes):await()
end

return ai
