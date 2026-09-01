-- elevenlabs audio adapter covering text to speech (buffered and streamed), speech to text, voice listing, and sound effects
local transport = require("ai.http")
local http = require("http")

local adapter = {}

local DEFAULT_VOICE = "21m00Tcm4TlvDq8ikWAM"
local DEFAULT_TTS_MODEL = "eleven_multilingual_v2"
local DEFAULT_STT_MODEL = "scribe_v2"
local DEFAULT_SFX_MODEL = "eleven_text_to_sound_v2"

local function headers(client, contentType)
    local out = {}
    if contentType then
        out["Content-Type"] = contentType
    end
    if client.apiKey then
        out["xi-api-key"] = client.apiKey
    end

    return out
end

-- raises a tagged error carrying the response body when the status is not 2xx
local function ensureOk(response, tag)
    if not response.ok then
        error(string.format("%s: http %d %s", tag, response.status, response.body), 0)
    end
end

-- builds a multipart/form-data body from ordered text fields and a single binary file part
local function multipart(fields, file)
    local boundary = "----varn" .. tostring(os.time()) .. tostring(#file.data)
    local parts = {}

    for _, field in ipairs(fields) do
        parts[#parts + 1] = "--" .. boundary
        parts[#parts + 1] = string.format('Content-Disposition: form-data; name="%s"', field[1])
        parts[#parts + 1] = ""
        parts[#parts + 1] = field[2]
    end

    parts[#parts + 1] = "--" .. boundary
    parts[#parts + 1] = string.format('Content-Disposition: form-data; name="%s"; filename="%s"', file.name, file.filename)
    parts[#parts + 1] = "Content-Type: " .. file.contentType
    parts[#parts + 1] = ""
    parts[#parts + 1] = file.data
    parts[#parts + 1] = "--" .. boundary .. "--"
    parts[#parts + 1] = ""

    return table.concat(parts, "\r\n"), "multipart/form-data; boundary=" .. boundary
end

function adapter.tts(client, request)
    local voice = request.voiceId or DEFAULT_VOICE
    local format = request.outputFormat or "mp3_44100_128"

    local response = transport.send({
        url = string.format("%s/v1/text-to-speech/%s?output_format=%s", client.baseUrl, voice, format),
        method = "POST",
        headers = headers(client, "application/json"),
        json = {
            text = request.text,
            model_id = request.model or DEFAULT_TTS_MODEL,
            language_code = request.languageCode,
            voice_settings = request.voiceSettings,
        },
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    })

    ensureOk(response, client.provider)
    return { audio = response.body, contentType = response.headers["content-type"] }
end

function adapter.ttsStream(client, request, onChunk)
    local voice = request.voiceId or DEFAULT_VOICE
    local format = request.outputFormat or "mp3_44100_128"

    local _, err = http.client.stream({
        url = string.format("%s/v1/text-to-speech/%s/stream?output_format=%s", client.baseUrl, voice, format),
        method = "POST",
        headers = headers(client, "application/json"),
        json = {
            text = request.text,
            model_id = request.model or DEFAULT_TTS_MODEL,
            language_code = request.languageCode,
            voice_settings = request.voiceSettings,
        },
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    }, onChunk):await()

    if err then
        error(err, 0)
    end
end

function adapter.stt(client, request)
    local fields = { { "model_id", request.model or DEFAULT_STT_MODEL } }
    if request.languageCode then
        fields[#fields + 1] = { "language_code", request.languageCode }
    end
    if request.diarize ~= nil then
        fields[#fields + 1] = { "diarize", tostring(request.diarize) }
    end

    local body, contentType = multipart(fields, {
        name = "file",
        filename = request.filename or "audio.mp3",
        contentType = request.contentType or "application/octet-stream",
        data = request.audio,
    })

    local response = transport.send({
        url = client.baseUrl .. "/v1/speech-to-text",
        method = "POST",
        headers = headers(client, contentType),
        body = body,
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    })

    ensureOk(response, client.provider)
    return response.json()
end

function adapter.voices(client)
    local data = transport.sendJson({
        url = client.baseUrl .. "/v2/voices",
        method = "GET",
        headers = headers(client),
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    return data.voices or {}
end

function adapter.soundEffect(client, request)
    local response = transport.send({
        url = client.baseUrl .. "/v1/sound-generation",
        method = "POST",
        headers = headers(client, "application/json"),
        json = {
            text = request.text,
            duration_seconds = request.durationSeconds,
            prompt_influence = request.promptInfluence,
            model_id = request.model or DEFAULT_SFX_MODEL,
        },
        timeoutSeconds = request.timeoutSeconds or client.timeoutSeconds or 120,
    })

    ensureOk(response, client.provider)
    return { audio = response.body, contentType = response.headers["content-type"] }
end

return adapter
