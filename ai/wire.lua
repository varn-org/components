-- helpers shared by every adapter for turning a resolved client and an openai-shaped request into an http request
local crypto = require("crypto")

local wire = {}

-- keys the client consumes to address the provider, never forwarded to the wire
local controlKeys = {
    model = true,
    api_key = true,
    api_base = true,
    api_version = true,
    extra_headers = true,
    timeout = true,
    stream = true,
    aws_region_name = true,
    aws_access_key_id = true,
    aws_session_token = true,
    vertex_project = true,
    vertex_location = true,
    iam_url = true,
}

function wire.isControlKey(key)
    return controlKeys[key] == true
end

-- copies the request onto the wire body, dropping the control keys and rewriting the model to its bare name
function wire.body(client, request)
    local body = {}
    for key, value in pairs(request) do
        if not controlKeys[key] then
            body[key] = value
        end
    end

    body.model = client.model
    return body
end

-- json headers carrying a bearer token, with the caller's extra headers applied last so they win
function wire.headers(client, extra)
    local out = { ["Content-Type"] = "application/json" }
    if client.apiKey then
        out["Authorization"] = "Bearer " .. client.apiKey
    end

    for key, value in pairs(extra or {}) do
        out[key] = value
    end

    for key, value in pairs(client.headers or {}) do
        out[key] = value
    end

    return out
end

-- a name, filename or media type owns its place on a header line, so a line break in one is refused and a quote is escaped rather than allowed to close the field
local function headerValue(field, text)
    text = tostring(text)

    if text:find("[\r\n%z]") then
        error(string.format("ai: multipart %s may not contain a line break", field), 0)
    end

    return (text:gsub("[\\\"]", "\\%0"))
end

-- encodes multipart/form-data from an ordered list of { name, value } and { name, filename, contentType, data } parts
function wire.multipart(parts)
    local boundary = "varnform" .. crypto.hexEncode(crypto.randomBytes(16))
    local chunks = {}

    for _, part in ipairs(parts) do
        if part.value ~= nil or part.data ~= nil then
            chunks[#chunks + 1] = "--" .. boundary .. "\r\n"

            if part.filename then
                chunks[#chunks + 1] = string.format(
                    'Content-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: %s\r\n\r\n',
                    headerValue("name", part.name),
                    headerValue("filename", part.filename),
                    headerValue("content type", part.contentType or "application/octet-stream")
                )
                chunks[#chunks + 1] = part.data
            else
                chunks[#chunks + 1] = string.format('Content-Disposition: form-data; name="%s"\r\n\r\n', headerValue("name", part.name))
                chunks[#chunks + 1] = tostring(part.value)
            end

            chunks[#chunks + 1] = "\r\n"
        end
    end

    chunks[#chunks + 1] = "--" .. boundary .. "--\r\n"

    return table.concat(chunks), "multipart/form-data; boundary=" .. boundary
end

-- merges one streamed openai delta into the message being assembled, concatenating text and growing tool calls by index
function wire.mergeDelta(message, delta)
    if delta.role then
        message.role = delta.role
    end

    if delta.content and delta.content ~= "" then
        message.content = (message.content or "") .. delta.content
    end

    local reasoning = delta.reasoning_content or delta.reasoning
    if reasoning and reasoning ~= "" then
        message.reasoning_content = (message.reasoning_content or "") .. reasoning
    end

    for _, call in ipairs(delta.tool_calls or {}) do
        local index = (call.index or 0) + 1
        message.tool_calls = message.tool_calls or {}

        local current = message.tool_calls[index]
        if not current then
            current = { index = call.index or 0, id = call.id, type = "function", ["function"] = { name = "", arguments = "" } }
            message.tool_calls[index] = current
        end

        if call.id then
            current.id = call.id
        end

        local fn = call["function"]
        if fn then
            if fn.name then
                current["function"].name = current["function"].name .. fn.name
            end
            if fn.arguments then
                current["function"].arguments = current["function"].arguments .. fn.arguments
            end
        end
    end
end

-- an openai-shaped chat completion built by the adapters that translate a native wire
function wire.completionResponse(fields)
    return {
        id = fields.id,
        object = "chat.completion",
        created = fields.created or os.time(),
        model = fields.model,
        choices = fields.choices,
        usage = fields.usage,
    }
end

-- an openai-shaped streaming chunk carrying a single delta
function wire.chunk(fields)
    return {
        id = fields.id,
        object = "chat.completion.chunk",
        created = fields.created or os.time(),
        model = fields.model,
        choices = {
            {
                index = 0,
                delta = fields.delta,
                finish_reason = fields.finish_reason,
            },
        },
    }
end

return wire
