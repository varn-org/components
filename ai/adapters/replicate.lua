-- replicate, whose models take a single prompt rather than a conversation, so the messages are rendered into one and the prediction is awaited inline
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

-- replicate has no conversation format of its own, so the turns are rendered into the prompt convention its chat models are trained on
local function renderPrompt(messages)
    local system = {}
    local turns = {}

    for _, message in ipairs(messages or {}) do
        local content = message.content
        if type(content) == "table" then
            local text = {}
            for _, part in ipairs(content) do
                if part.type == "text" then
                    text[#text + 1] = part.text
                end
            end
            content = table.concat(text)
        end

        if message.role == "system" then
            system[#system + 1] = content
        elseif message.role == "assistant" then
            turns[#turns + 1] = "Assistant: " .. (content or "")
        else
            turns[#turns + 1] = "User: " .. (content or "")
        end
    end

    turns[#turns + 1] = "Assistant:"

    return (#system > 0 and table.concat(system, "\n") or nil), table.concat(turns, "\n")
end

-- the model name carries an owner and may pin a version after a colon, which addresses a different endpoint
local function endpoint(client)
    local name, version = client.model:match("^(.-):(.+)$")
    if version then
        return client.baseUrl .. "/predictions", version
    end

    return string.format("%s/models/%s/predictions", client.baseUrl, name or client.model), nil
end

function adapter.completion(client, request)
    local system, prompt = renderPrompt(request.messages)
    local url, version = endpoint(client)

    local input = {
        prompt = prompt,
        system_prompt = request.system or system,
        temperature = request.temperature,
        top_p = request.top_p,
        max_tokens = request.max_tokens,
        stop_sequences = type(request.stop) == "table" and table.concat(request.stop, ",") or request.stop,
    }

    -- the wait preference makes replicate hold the request open until the prediction finishes instead of returning a job to poll
    local data = transport.sendJson({
        url = url,
        method = "POST",
        headers = wire.headers(client, { ["Prefer"] = "wait" }),
        json = { version = version, input = input },
        timeoutSeconds = client.timeoutSeconds or 120,
    }, client.provider)

    if data.status ~= "succeeded" then
        error(string.format("%s: prediction %s: %s", client.provider, tostring(data.status), tostring(data.error)), 0)
    end

    local output = data.output
    if type(output) == "table" then
        output = table.concat(output)
    end

    return wire.completionResponse({
        id = data.id,
        model = client.model,
        choices = { { index = 0, message = { role = "assistant", content = output }, finish_reason = "stop" } },
    })
end

-- replicate answers a streaming prediction with a url to follow rather than the tokens themselves, so the job is created first and read second
function adapter.streamCompletion(client, request, onChunk)
    local system, prompt = renderPrompt(request.messages)
    local url, version = endpoint(client)

    local created = transport.sendJson({
        url = url,
        method = "POST",
        headers = wire.headers(client),
        json = {
            version = version,
            stream = true,
            input = {
                prompt = prompt,
                system_prompt = request.system or system,
                temperature = request.temperature,
                top_p = request.top_p,
                max_tokens = request.max_tokens,
            },
        },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    local streamUrl = created.urls and created.urls.stream
    if not streamUrl then
        error(string.format("%s: prediction did not return a stream url", client.provider), 0)
    end

    local message = { role = "assistant" }
    local finishReason

    onChunk(wire.chunk({ id = created.id, model = client.model, delta = { role = "assistant" } }))

    transport.sse({
        url = streamUrl,
        method = "GET",
        headers = wire.headers(client, { ["Accept"] = "text/event-stream" }),
        timeoutSeconds = client.timeoutSeconds or 120,
    }, function(name, payload)
        if name == "error" then
            error(string.format("%s: %s", client.provider, payload), 0)
        end

        if name == "done" then
            finishReason = "stop"
            onChunk(wire.chunk({ id = created.id, model = client.model, delta = {}, finish_reason = finishReason }))
            return
        end

        if payload ~= "" then
            message.content = (message.content or "") .. payload
            onChunk(wire.chunk({ id = created.id, model = client.model, delta = { content = payload } }))
        end
    end, client.provider)

    return wire.completionResponse({
        id = created.id,
        model = client.model,
        choices = { { index = 0, message = message, finish_reason = finishReason or "stop" } },
    })
end

return adapter
