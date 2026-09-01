-- transport helpers over the native http client giving every ai adapter json requests, sse streaming, and raw binary bodies, all of which yield on the event loop so they must run inside an async coroutine
local http = require("http")

local transport = {}

-- performs a request and returns the ergonomic response, raising the transport error string on a connection failure
function transport.send(options)
    local response, err = http.client.request(options):await()
    if err then
        error(err, 0)
    end

    return response
end

-- performs a request expecting json and returns the decoded body, raising a tagged error on a non-2xx status
function transport.sendJson(options, tag)
    local response = transport.send(options)
    if not response.ok then
        error(string.format("%s: http %d %s", tag, response.status, response.body), 0)
    end

    return response.json(), response
end

-- streams a server-sent-events response, invoking handler(eventName, data) per event, and raises the error body when the status is not 200
function transport.sse(options, handler, tag)
    local status
    local errorBody = {}
    local buffer = ""
    local eventName
    local dataLines = {}

    local function flush()
        if #dataLines > 0 then
            handler(eventName, table.concat(dataLines, "\n"))
        end
        eventName = nil
        dataLines = {}
    end

    local function onChunk(chunk)
        if status and status ~= 200 then
            errorBody[#errorBody + 1] = chunk
            return
        end

        buffer = buffer .. chunk
        while true do
            local newline = buffer:find("\n", 1, true)
            if not newline then
                break
            end

            local line = buffer:sub(1, newline - 1):gsub("\r$", "")
            buffer = buffer:sub(newline + 1)

            if line == "" then
                flush()
            elseif line:sub(1, 1) ~= ":" then
                local field, value = line:match("^([%w_]+):%s?(.*)$")
                if field == "data" then
                    dataLines[#dataLines + 1] = value
                elseif field == "event" then
                    eventName = value
                end
            end
        end
    end

    local streamOptions = {}
    for key, value in pairs(options) do
        streamOptions[key] = value
    end
    streamOptions.onResponse = function(responseStatus)
        status = responseStatus
    end

    local _, err = http.client.stream(streamOptions, onChunk):await()
    if err then
        error(err, 0)
    end

    flush()

    if status and status ~= 200 then
        error(string.format("%s: http %d %s", tag, status, table.concat(errorBody)), 0)
    end
end

return transport
