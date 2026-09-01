-- elevenlabs speech, which addresses a voice in the path for synthesis and takes an upload for recognition
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

local function headers(client, extra)
    local out = {}
    if client.apiKey then
        out["xi-api-key"] = client.apiKey
    end

    for key, value in pairs(extra or {}) do
        out[key] = value
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- returns the raw audio bytes, matching what the openai speech endpoint answers with
function adapter.speech(client, request)
    if not request.voice then
        error("ai: elevenlabs needs voice as the voice id", 0)
    end

    local response = transport.send({
        url = string.format("%s/v1/text-to-speech/%s", client.baseUrl, request.voice),
        method = "POST",
        headers = headers(client, { ["Content-Type"] = "application/json" }),
        json = {
            text = request.input,
            model_id = client.model,
            voice_settings = request.voice_settings,
            output_format = request.response_format,
        },
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    return response.body
end

function adapter.transcription(client, request)
    if type(request.file) ~= "string" then
        error("ai: transcription needs request.file as the audio bytes", 0)
    end

    local body, contentType = wire.multipart({
        { name = "file", filename = request.file_name or "audio.mp3", contentType = request.content_type, data = request.file },
        { name = "model_id", value = client.model },
        { name = "language_code", value = request.language },
    })

    local response = transport.send({
        url = client.baseUrl .. "/v1/speech-to-text",
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

return adapter
