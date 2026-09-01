-- the dedicated image providers, each a single generation call whose answer is normalised into the openai image shape
local async = require("async")
local json = require("json")
local transport = require("ai.http")
local wire = require("ai.wire")

local adapter = {}

-- black forest labs answers with a job to poll rather than the finished image
local function awaitBfl(client, pollingUrl)
    local deadline = os.time() + (client.timeoutSeconds or 120)

    while os.time() < deadline do
        local data = transport.sendJson({
            url = pollingUrl,
            method = "GET",
            headers = wire.headers(client, { ["x-key"] = client.apiKey }),
            timeoutSeconds = client.timeoutSeconds,
        }, client.provider)

        if data.status == "Ready" then
            return data.result
        end

        if data.status ~= "Pending" and data.status ~= "Request Moderated" then
            error(string.format("%s: generation %s", client.provider, tostring(data.status)), 0)
        end

        async.sleep(1000):await()
    end

    error(string.format("%s: generation did not finish within the timeout", client.provider), 0)
end

local generators = {}

function generators.fal_ai(client, request)
    local data = transport.sendJson({
        url = string.format("%s/%s", client.baseUrl, client.model),
        method = "POST",
        headers = wire.headers(client, { ["Authorization"] = "Key " .. tostring(client.apiKey) }),
        json = {
            prompt = request.prompt,
            num_images = request.n,
            image_size = request.size,
            seed = request.seed,
        },
        timeoutSeconds = client.timeoutSeconds or 120,
    }, client.provider)

    local images = {}
    for _, image in ipairs(data.images or {}) do
        images[#images + 1] = { url = image.url }
    end

    return images
end

function generators.stability(client, request)
    local body, contentType = wire.multipart({
        { name = "prompt", value = request.prompt },
        { name = "output_format", value = "png" },
        { name = "aspect_ratio", value = request.size },
        { name = "seed", value = request.seed },
    })

    local response = transport.send({
        url = string.format("%s/v2beta/stable-image/generate/%s", client.baseUrl, client.model),
        method = "POST",
        headers = wire.headers(client, { ["Content-Type"] = contentType, ["Accept"] = "application/json" }),
        body = body,
        timeoutSeconds = client.timeoutSeconds or 120,
    })

    if not response.ok then
        error(string.format("%s: http %d %s", client.provider, response.status, response.body), 0)
    end

    local data = response.json()
    return { { b64_json = data.image } }
end

function generators.black_forest_labs(client, request)
    local queued = transport.sendJson({
        url = string.format("%s/v1/%s", client.baseUrl, client.model),
        method = "POST",
        headers = wire.headers(client, { ["x-key"] = client.apiKey }),
        json = {
            prompt = request.prompt,
            width = request.width,
            height = request.height,
            seed = request.seed,
            output_format = "png",
        },
        timeoutSeconds = client.timeoutSeconds,
    }, client.provider)

    if not queued.polling_url then
        error(string.format("%s: generation did not return a polling url", client.provider), 0)
    end

    local result = awaitBfl(client, queued.polling_url)
    return { { url = result and result.sample } }
end

function adapter.imageGeneration(client, request)
    local generate = generators[client.provider]
    if not generate then
        error(string.format("ai: provider %s does not serve image generation", client.provider), 0)
    end

    return { created = os.time(), data = generate(client, request) }
end

-- fal language models take the conversation rendered into one prompt with the system turns kept apart
local function falPrompt(messages)
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
        else
            turns[#turns + 1] = content
        end
    end

    return (#system > 0 and table.concat(system, "\n") or nil), table.concat(turns, "\n")
end

function adapter.completion(client, request)
    if client.provider ~= "fal_ai" then
        error(string.format("ai: provider %s does not serve completion", client.provider), 0)
    end

    local system, turns = falPrompt(request.messages)

    local data = transport.sendJson({
        url = string.format("%s/%s", client.baseUrl, client.model),
        method = "POST",
        headers = wire.headers(client, { ["Authorization"] = "Key " .. tostring(client.apiKey) }),
        json = { prompt = turns, system_prompt = system },
        timeoutSeconds = client.timeoutSeconds or 120,
    }, client.provider)

    return wire.completionResponse({
        model = client.model,
        choices = { { index = 0, message = { role = "assistant", content = data.output }, finish_reason = "stop" } },
    })
end

-- fal streams from a sibling path of the model endpoint, sending the whole output so far in each event rather than the new piece
function adapter.streamCompletion(client, request, onChunk)
    if client.provider ~= "fal_ai" then
        error(string.format("ai: provider %s does not serve completion", client.provider), 0)
    end

    local system, turns = falPrompt(request.messages)
    local content = ""

    onChunk(wire.chunk({ model = client.model, delta = { role = "assistant" } }))

    transport.sse({
        url = string.format("%s/%s/stream", client.baseUrl, client.model),
        method = "POST",
        headers = wire.headers(client, { ["Authorization"] = "Key " .. tostring(client.apiKey) }),
        json = { prompt = turns, system_prompt = system },
        timeoutSeconds = client.timeoutSeconds or 120,
    }, function(_, payload)
        local event = json.decode(payload)
        local output = event.output or ""

        if #output > #content then
            local delta = output:sub(#content + 1)
            content = output
            onChunk(wire.chunk({ model = client.model, delta = { content = delta } }))
        end
    end, client.provider)

    onChunk(wire.chunk({ model = client.model, delta = {}, finish_reason = "stop" }))

    return wire.completionResponse({
        model = client.model,
        choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
    })
end

return adapter
