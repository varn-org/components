-- deepgram transcription, which takes the audio as the raw request body and selects the model on the query string
local http = require("http")
local transport = require("ai.http")

local adapter = {}

-- deepgram authenticates with its own token scheme rather than a bearer
local function headers(client, contentType)
    local out = { ["Content-Type"] = contentType or "application/octet-stream" }
    if client.apiKey then
        out["Authorization"] = "Token " .. client.apiKey
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- every option other than the audio itself travels as a query parameter
local function query(client, request)
    local pairsList = { "model=" .. http.urlEncode(client.model) }

    for key, value in pairs(request) do
        if key ~= "file" and key ~= "file_name" and key ~= "content_type" and key ~= "model" then
            if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then
                pairsList[#pairsList + 1] = http.urlEncode(key) .. "=" .. http.urlEncode(tostring(value))
            end
        end
    end

    table.sort(pairsList)
    return "?" .. table.concat(pairsList, "&")
end

function adapter.transcription(client, request)
    if type(request.file) ~= "string" then
        error("ai: transcription needs request.file as the audio bytes", 0)
    end

    local response = transport.send({
        url = client.baseUrl .. "/listen" .. query(client, request),
        method = "POST",
        headers = headers(client, request.content_type),
        body = request.file,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    local data = response.json()
    local alternative = data.results
        and data.results.channels
        and data.results.channels[1]
        and data.results.channels[1].alternatives
        and data.results.channels[1].alternatives[1]

    return { text = alternative and alternative.transcript, raw = data }
end

return adapter
