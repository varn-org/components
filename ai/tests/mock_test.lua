-- deterministic adapter test against a local mock server, asserting both the body each adapter puts on the wire and the openai-shaped response it returns, with no network and no api keys
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local http = require("http")
local json = require("json")
local ai = require("ai")

local port = 39901
local base = "http://127.0.0.1:" .. port

-- the last body each route received, so a test can assert on what the adapter actually sent
local seen = {}

local app = http.createApp()

app:post("/chat/completions", function(ctx)
    local body = ctx:body()
    seen.chat = body

    if body.stream then
        local sse = ctx:sse()
        sse:send(json.encode({ id = "c1", model = "mock", choices = { { index = 0, delta = { role = "assistant" } } } }))
        sse:send(json.encode({ id = "c1", model = "mock", choices = { { index = 0, delta = { content = "Hello" } } } }))
        sse:send(json.encode({ id = "c1", model = "mock", choices = { { index = 0, delta = { content = " world" } } } }))
        sse:send(json.encode({
            id = "c1",
            model = "mock",
            choices = { { index = 0, delta = {}, finish_reason = "stop" } },
            usage = { prompt_tokens = 3, completion_tokens = 2, total_tokens = 5 },
        }))
        sse:send("[DONE]")
        sse:close()
        return
    end

    if body.tools then
        ctx:json({
            id = "c2",
            model = "mock",
            choices = {
                {
                    index = 0,
                    message = {
                        role = "assistant",
                        tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "get_weather", arguments = '{"city":"Paris"}' } } },
                    },
                    finish_reason = "tool_calls",
                },
            },
        })
        return
    end

    ctx:json({
        id = "c3",
        model = "mock",
        choices = { { index = 0, message = { role = "assistant", content = "hi there" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 },
    })
end)

app:post("/embeddings", function(ctx)
    seen.embeddings = ctx:body()
    ctx:json({ object = "list", data = { { object = "embedding", index = 0, embedding = { 0.1, 0.2 } } }, usage = { prompt_tokens = 2, total_tokens = 2 } })
end)

app:post("/images/generations", function(ctx)
    seen.images = ctx:body()
    ctx:json({ created = 1, data = { { b64_json = "aGk=" } } })
end)

app:post("/moderations", function(ctx)
    seen.moderations = ctx:body()
    ctx:json({ id = "m1", model = "mock", results = { { flagged = false } } })
end)

app:post("/audio/transcriptions", function(ctx)
    local headers = ctx.request.headers
    seen.transcription = { raw = ctx:body(), contentType = headers["Content-Type"] or headers["content-type"] }
    ctx:json({ text = "transcribed" })
end)

app:post("/audio/speech", function(ctx)
    seen.speech = ctx:body()
    ctx:header("Content-Type", "audio/mpeg")
    ctx:send("BINARYAUDIO")
end)

app:post("/v1/messages", function(ctx)
    local body = ctx:body()
    seen.messages = body

    if body.stream then
        local sse = ctx:sse()
        local function event(name, payload)
            sse:send(name, json.encode(payload))
        end

        event("message_start", { type = "message_start", message = { id = "m1", model = "claude-mock", usage = { input_tokens = 7, output_tokens = 0 } } })
        event("content_block_start", { type = "content_block_start", index = 0, content_block = { type = "text", text = "" } })
        event("content_block_delta", { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Bonjour" } })
        event("content_block_delta", { type = "content_block_delta", index = 0, delta = { type = "text_delta", text = " monde" } })
        event("content_block_stop", { type = "content_block_stop", index = 0 })
        event("content_block_start", { type = "content_block_start", index = 1, content_block = { type = "tool_use", id = "toolu_1", name = "lookup", input = {} } })
        event("content_block_delta", { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '{"q":' } })
        event("content_block_delta", { type = "content_block_delta", index = 1, delta = { type = "input_json_delta", partial_json = '"paris"}' } })
        event("content_block_stop", { type = "content_block_stop", index = 1 })
        event("message_delta", { type = "message_delta", delta = { stop_reason = "tool_use" }, usage = { output_tokens = 11 } })
        event("message_stop", { type = "message_stop" })
        sse:close()
        return
    end

    ctx:json({
        id = "msg_1",
        model = "claude-mock",
        content = { { type = "text", text = "claude says hi" } },
        stop_reason = "end_turn",
        usage = { input_tokens = 4, output_tokens = 3 },
    })
end)

app:post("/files", function(ctx)
    seen.files = ctx:body()
    ctx:json({ id = "file-1", object = "file", purpose = "batch", bytes = 18 })
end)

app:post("/batches", function(ctx)
    seen.batchCreate = ctx:body()
    ctx:json({ id = "batch-1", object = "batch", status = "validating", endpoint = seen.batchCreate.endpoint })
end)

app:get("/batches", function(ctx)
    ctx:json({ object = "list", data = { { id = "batch-1", status = "completed" } } })
end)

app:get("/batches/:id", function(ctx)
    if ctx.params.id == "pending" then
        ctx:json({ id = "pending", object = "batch", status = "in_progress" })
        return
    end
    ctx:json({ id = ctx.params.id, object = "batch", status = "completed", output_file_id = "file-out" })
end)

app:post("/batches/:id/cancel", function(ctx)
    ctx:json({ id = ctx.params.id, object = "batch", status = "cancelling" })
end)

app:get("/files/:id/content", function(ctx)
    ctx:send('{"custom_id":"a","response":{"status_code":200}}\n{"custom_id":"b","response":{"status_code":200}}\n')
end)

app:post("/rerank", function(ctx)
    seen.rerank = ctx:body()
    ctx:json({ results = { { index = 0, relevance_score = 0.7 } } })
end)

app:post("/reranks", function(ctx)
    seen.reranks = { body = ctx:body(), path = ctx.request.path }
    ctx:json({ results = { { index = 0, relevance_score = 0.5 } } })
end)

app:post("/compatible-api/v1/reranks", function(ctx)
    seen.qwenRerank = ctx.request.path
    ctx:json({ results = {} })
end)

app:post("/v1beta/models/:model", function(ctx)
    seen.gemini = ctx:body()
    seen.geminiModel = ctx.params.model

    if seen.geminiModel:find(":streamGenerateContent") then
        local sse = ctx:sse()
        sse:send(json.encode({
            responseId = "g1",
            modelVersion = "gemini-mock",
            candidates = { { content = { role = "model", parts = { { text = "Olá" } } } } },
        }))
        sse:send(json.encode({
            responseId = "g1",
            candidates = { { content = { role = "model", parts = { { text = " mundo" } } }, finishReason = "STOP" } },
            usageMetadata = { promptTokenCount = 2, candidatesTokenCount = 3, totalTokenCount = 5 },
        }))
        sse:close()
        return
    end

    ctx:json({
        responseId = "g2",
        modelVersion = "gemini-mock",
        candidates = {
            {
                content = { role = "model", parts = { { text = "gemini says hi" }, { functionCall = { name = "lookup", args = { q = "paris" } } } } },
                finishReason = "STOP",
            },
        },
        usageMetadata = { promptTokenCount = 6, candidatesTokenCount = 2, totalTokenCount = 8 },
    })
end)

app:post("/v2/chat", function(ctx)
    seen.cohere = ctx:body()
    ctx:json({
        id = "co1",
        message = { role = "assistant", content = { { type = "text", text = "cohere says hi" } } },
        finish_reason = "COMPLETE",
        usage = { tokens = { input_tokens = 5, output_tokens = 4 } },
    })
end)

app:post("/openai/deployments/:deployment/chat/completions", function(ctx)
    seen.azure = { body = ctx:body(), deployment = ctx.params.deployment, query = ctx.request.query, key = ctx.request.headers["api-key"] }
    ctx:json({
        id = "az1",
        model = "gpt-4o",
        choices = { { index = 0, message = { role = "assistant", content = "azure says hi" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 1, completion_tokens = 2, total_tokens = 3 },
    })
end)

app:post("/model/:model/converse", function(ctx)
    seen.bedrock = { body = ctx:body(), model = ctx.params.model, auth = ctx.request.headers["Authorization"] or ctx.request.headers["authorization"] }
    ctx:json({
        output = {
            message = {
                role = "assistant",
                content = { { text = "bedrock says hi" }, { toolUse = { toolUseId = "tu1", name = "lookup", input = { q = "paris" } } } },
            },
        },
        stopReason = "tool_use",
        usage = { inputTokens = 9, outputTokens = 4, totalTokens = 13 },
    })
end)

app:listen({ host = "127.0.0.1", port = port })

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

async.run(function()
    -- the openai wire carries the request through unchanged and answers the openai shape verbatim
    local reply = ai.completion({
        model = "openai/gpt-4o",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "test",
        temperature = 0.2,
    })
    check(reply.choices[1].message.content == "hi there", "openai content mismatch")
    check(reply.choices[1].finish_reason == "stop", "openai finish mismatch")
    check(reply.usage.total_tokens == 2, "openai usage mismatch")
    check(seen.chat.model == "gpt-4o", "openai must send the bare model name")
    check(seen.chat.temperature == 0.2, "openai must pass parameters through")
    check(seen.chat.api_key == nil and seen.chat.api_base == nil, "control keys must not reach the wire")

    -- a bare model name resolves to openai
    local bare = ai.completion({ model = "gpt-4o-mini", messages = { { role = "user", content = "hi" } }, api_base = base })
    check(bare.choices[1].message.content == "hi there", "bare model mismatch")
    check(seen.chat.model == "gpt-4o-mini", "bare model must reach the wire unchanged")

    -- an openai-compatible provider differs only in endpoint, so the same wire serves it
    local groq = ai.completion({ model = "groq/llama-3.3-70b", messages = { { role = "user", content = "hi" } }, api_base = base })
    check(groq.choices[1].message.content == "hi there", "groq content mismatch")
    check(seen.chat.model == "llama-3.3-70b", "groq model mismatch")

    -- a slash inside the model name belongs to the model, not the provider
    ai.completion({ model = "openrouter/anthropic/claude-sonnet-4", messages = { { role = "user", content = "hi" } }, api_base = base })
    check(seen.chat.model == "anthropic/claude-sonnet-4", "openrouter must keep the vendor prefix in the model")

    -- streaming yields openai chunks and still returns the assembled response
    local deltas = {}
    local streamed = ai.completion({
        model = "openai/gpt-4o",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            deltas[#deltas + 1] = content
        end
    end)
    check(table.concat(deltas) == "Hello world", "openai stream deltas mismatch")
    check(streamed.choices[1].message.content == "Hello world", "openai stream assembly mismatch")
    check(streamed.choices[1].finish_reason == "stop", "openai stream finish mismatch")
    check(streamed.usage.total_tokens == 5, "openai stream usage mismatch")
    check(seen.chat.stream == true, "stream flag must reach the wire")

    -- tools cross unchanged and come back as openai tool_calls
    local tooled = ai.completion({
        model = "openai/gpt-4o",
        messages = { { role = "user", content = "weather" } },
        tools = { { type = "function", ["function"] = { name = "get_weather", parameters = { type = "object" } } } },
        api_base = base,
    })
    local call = tooled.choices[1].message.tool_calls[1]
    check(call["function"].name == "get_weather", "tool name mismatch")
    check(call["function"].arguments == '{"city":"Paris"}', "tool arguments mismatch")
    check(tooled.choices[1].finish_reason == "tool_calls", "tool finish mismatch")

    -- the remaining openai endpoints
    local embedded = ai.embedding({ model = "openai/text-embedding-3-small", input = "hi", api_base = base })
    check(embedded.data[1].embedding[2] == 0.2, "embedding mismatch")
    check(seen.embeddings.model == "text-embedding-3-small", "embedding model mismatch")

    local image = ai.imageGeneration({ model = "openai/dall-e-3", prompt = "a cat", api_base = base })
    check(image.data[1].b64_json == "aGk=", "image mismatch")
    check(seen.images.prompt == "a cat", "image prompt mismatch")

    local moderated = ai.moderation({ model = "openai/omni-moderation-latest", input = "hi", api_base = base })
    check(moderated.results[1].flagged == false, "moderation mismatch")

    local transcript = ai.transcription({ model = "openai/whisper-1", file = "RIFFDATA", file_name = "a.wav", api_base = base })
    check(transcript.text == "transcribed", "transcription mismatch")
    check(seen.transcription.contentType:find("multipart/form%-data; boundary="), "transcription must send multipart")
    local uploaded = seen.transcription.raw.files[1]
    check(uploaded.field == "file" and uploaded.data == "RIFFDATA", "transcription must carry the audio bytes")
    check(uploaded.filename == "a.wav", "transcription filename mismatch")
    check(seen.transcription.raw.fields.model == "whisper-1", "transcription model mismatch")

    local audio = ai.speech({ model = "openai/tts-1", input = "hi", voice = "alloy", api_base = base })
    check(audio == "BINARYAUDIO", "speech must return raw bytes")
    check(seen.speech.voice == "alloy", "speech voice mismatch")

    -- anthropic takes a different wire in both directions
    local claude = ai.completion({
        model = "anthropic/claude-sonnet-4-5",
        messages = {
            { role = "system", content = "be brief" },
            { role = "user", content = "hi" },
        },
        max_tokens = 100,
        api_base = base,
        api_key = "test",
    })
    check(claude.choices[1].message.content == "claude says hi", "anthropic content mismatch")
    check(claude.choices[1].finish_reason == "stop", "anthropic must map end_turn to stop")
    check(claude.usage.total_tokens == 7, "anthropic usage mismatch")
    check(seen.messages.system[1].text == "be brief", "anthropic must lift system out of messages")
    check(#seen.messages.messages == 1, "anthropic must not leave system in the conversation")
    check(seen.messages.messages[1].content[1].type == "text", "anthropic must send content blocks")

    -- an openai tool definition and a tool result become anthropic shapes
    ai.completion({
        model = "anthropic/claude-sonnet-4-5",
        messages = {
            { role = "user", content = "weather" },
            { role = "assistant", tool_calls = { { id = "t1", type = "function", ["function"] = { name = "lookup", arguments = '{"q":"paris"}' } } } },
            { role = "tool", tool_call_id = "t1", content = "sunny" },
        },
        tools = { { type = "function", ["function"] = { name = "lookup", description = "d", parameters = { type = "object" } } } },
        tool_choice = "required",
        max_tokens = 50,
        api_base = base,
    })
    check(seen.messages.tools[1].name == "lookup", "anthropic tool name mismatch")
    check(seen.messages.tools[1].input_schema.type == "object", "anthropic must rename parameters to input_schema")
    check(seen.messages.tool_choice.type == "any", "anthropic must map required to any")
    check(seen.messages.messages[2].content[1].type == "tool_use", "anthropic must send tool_use for an assistant call")
    check(seen.messages.messages[2].content[1].input.q == "paris", "anthropic must decode tool arguments")
    check(seen.messages.messages[3].content[1].type == "tool_result", "anthropic must send tool_result for a tool turn")
    check(seen.messages.messages[3].content[1].tool_use_id == "t1", "anthropic tool_result id mismatch")

    -- anthropic streaming maps its event protocol onto openai chunks
    local claudeDeltas = {}
    local claudeStream = ai.completion({
        model = "anthropic/claude-sonnet-4-5",
        messages = { { role = "user", content = "hi" } },
        max_tokens = 100,
        api_base = base,
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            claudeDeltas[#claudeDeltas + 1] = content
        end
    end)
    check(table.concat(claudeDeltas) == "Bonjour monde", "anthropic stream deltas mismatch")
    check(claudeStream.choices[1].message.content == "Bonjour monde", "anthropic stream assembly mismatch")
    check(claudeStream.choices[1].finish_reason == "tool_calls", "anthropic must map tool_use to tool_calls")
    local streamedCall = claudeStream.choices[1].message.tool_calls[1]
    check(streamedCall["function"].name == "lookup", "anthropic stream tool name mismatch")
    check(streamedCall["function"].arguments == '{"q":"paris"}', "anthropic must join input_json_delta fragments")
    check(claudeStream.usage.prompt_tokens == 7 and claudeStream.usage.completion_tokens == 11, "anthropic stream usage mismatch")

    -- anthropic requires max_tokens, and the client says so instead of letting the api reject it
    local ok, err = pcall(ai.completion, {
        model = "anthropic/claude-sonnet-4-5",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
    })
    check(not ok and tostring(err):find("max_tokens"), "anthropic must demand max_tokens")

    -- a provider with no default endpoint names the variable to set rather than guessing one
    local missing, missingErr = pcall(ai.completion, { model = "databricks/dbrx", messages = {} })
    check(not missing and tostring(missingErr):find("DATABRICKS_API_BASE"), "missing endpoint must name its variable")

    -- gemini renames roles and lifts the system prompt into its own field
    local gemini = ai.completion({
        model = "gemini/gemini-2.5-pro",
        messages = {
            { role = "system", content = "be brief" },
            { role = "user", content = "hi" },
        },
        temperature = 0.5,
        max_tokens = 64,
        api_base = base,
        api_key = "test",
    })
    check(gemini.choices[1].message.content == "gemini says hi", "gemini content mismatch")
    check(gemini.choices[1].finish_reason == "stop", "gemini must map STOP to stop")
    check(gemini.usage.total_tokens == 8, "gemini usage mismatch")
    check(seen.gemini.systemInstruction.parts[1].text == "be brief", "gemini must lift the system prompt")
    check(seen.gemini.contents[1].role == "user", "gemini role mismatch")
    check(seen.gemini.generationConfig.maxOutputTokens == 64, "gemini must rename max_tokens")
    check(seen.gemini.generationConfig.temperature == 0.5, "gemini temperature mismatch")

    -- a gemini function call has no id of its own, so the client gives it one to keep the round trip addressable
    local geminiCall = gemini.choices[1].message.tool_calls[1]
    check(geminiCall["function"].name == "lookup", "gemini tool name mismatch")
    check(json.decode(geminiCall["function"].arguments).q == "paris", "gemini tool arguments mismatch")
    check(geminiCall.id and geminiCall.id ~= "", "gemini tool call needs a synthesized id")

    local geminiDeltas = {}
    local geminiStream = ai.completion({
        model = "gemini/gemini-2.5-flash",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            geminiDeltas[#geminiDeltas + 1] = content
        end
    end)
    check(table.concat(geminiDeltas) == "Olá mundo", "gemini stream deltas mismatch")
    check(geminiStream.choices[1].message.content == "Olá mundo", "gemini stream assembly mismatch")
    check(geminiStream.choices[1].finish_reason == "stop", "gemini stream finish mismatch")

    -- an assistant tool call and its result round trip back into gemini parts
    ai.completion({
        model = "gemini/gemini-2.5-pro",
        messages = {
            { role = "user", content = "weather" },
            { role = "assistant", tool_calls = { { id = "t1", type = "function", ["function"] = { name = "lookup", arguments = '{"q":"paris"}' } } } },
            { role = "tool", tool_call_id = "t1", content = "sunny" },
        },
        api_base = base,
    })
    check(seen.gemini.contents[2].role == "model", "gemini must call the assistant model")
    check(seen.gemini.contents[2].parts[1].functionCall.name == "lookup", "gemini functionCall mismatch")
    check(seen.gemini.contents[3].parts[1].functionResponse.name == "lookup", "gemini must resolve the tool name from the call id")

    -- cohere v2 renames top_p and its stop reasons
    local cohere = ai.completion({
        model = "cohere/command-a",
        messages = { { role = "user", content = "hi" } },
        top_p = 0.9,
        api_base = base,
        api_key = "test",
    })
    check(cohere.choices[1].message.content == "cohere says hi", "cohere content mismatch")
    check(cohere.choices[1].finish_reason == "stop", "cohere must map COMPLETE to stop")
    check(cohere.usage.total_tokens == 9, "cohere usage mismatch")
    check(seen.cohere.p == 0.9, "cohere must rename top_p to p")

    -- azure addresses a deployment and authenticates with its own header
    local azure = ai.completion({
        model = "azure/my-deployment",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "azure-key",
        api_version = "2024-10-21",
    })
    check(azure.choices[1].message.content == "azure says hi", "azure content mismatch")
    check(seen.azure.deployment == "my-deployment", "azure must put the model in the path")
    check(seen.azure.query["api-version"] == "2024-10-21", "azure must send api-version")
    check(seen.azure.key == "azure-key", "azure must authenticate with the api-key header")
    check(seen.azure.body.model == nil, "azure must not repeat the model in the body")

    -- bedrock signs with sigv4 and speaks the converse wire
    local bedrock = ai.completion({
        model = "bedrock/anthropic.claude-sonnet-4-5-v1:0",
        messages = {
            { role = "system", content = "be brief" },
            { role = "user", content = "hi" },
        },
        max_tokens = 128,
        api_base = base,
        api_key = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        aws_access_key_id = "AKIDEXAMPLE",
        aws_region_name = "us-east-1",
    })
    check(bedrock.choices[1].message.content == "bedrock says hi", "bedrock content mismatch")
    check(bedrock.choices[1].finish_reason == "tool_calls", "bedrock must map tool_use to tool_calls")
    check(bedrock.usage.total_tokens == 13, "bedrock usage mismatch")
    check(bedrock.choices[1].message.tool_calls[1].id == "tu1", "bedrock tool id mismatch")
    check(seen.bedrock.body.system[1].text == "be brief", "bedrock must lift the system prompt")
    check(seen.bedrock.body.inferenceConfig.maxTokens == 128, "bedrock must rename max_tokens")
    check(seen.bedrock.auth:find("^AWS4%-HMAC%-SHA256 Credential=AKIDEXAMPLE/%d+/us%-east%-1/bedrock/aws4_request"), "bedrock credential scope mismatch: " .. tostring(seen.bedrock.auth))
    check(seen.bedrock.auth:find("SignedHeaders=content%-type;host;x%-amz%-content%-sha256;x%-amz%-date"), "bedrock signed headers mismatch")
    check(seen.bedrock.auth:find("Signature=%x%x%x%x%x%x%x%x"), "bedrock signature mismatch")

    -- the signing key derivation matches the vector aws publishes for it
    local derived = require("ai.sigv4").signingKey("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam")
    check(
        require("crypto").hexEncode(derived) == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d",
        "sigv4 signing key does not match the published aws vector"
    )

    -- every provider that serves chat also streams it, so no adapter is missing the path
    for _, slug in ipairs({ "openai", "anthropic", "gemini", "cohere", "azure", "bedrock", "watsonx", "replicate", "fal_ai" }) do
        local profile = require("ai.providers")[slug]
        local adapter = require("ai.adapters." .. profile.adapter)
        check(adapter.completion and adapter.streamCompletion, slug .. " serves chat but cannot stream it")
    end

    -- the message surface addresses any provider with content blocks and a system prompt of its own
    local messaged = ai.messages({
        model = "openai/gpt-4o",
        system = "be brief",
        messages = { { role = "user", content = { { type = "text", text = "hi" } } } },
        max_tokens = 64,
        api_base = base,
    })
    check(messaged.type == "message" and messaged.role == "assistant", "messages must answer in the message shape")
    check(messaged.content[1].type == "text" and messaged.content[1].text == "hi there", "messages content mismatch")
    check(messaged.stop_reason == "end_turn", "messages must map stop back to end_turn")
    check(messaged.usage.input_tokens == 1 and messaged.usage.output_tokens == 1, "messages usage mismatch")
    check(seen.chat.messages[1].role == "system", "messages must lower the system prompt into a chat turn")
    check(seen.chat.messages[2].content == "hi", "messages must flatten a lone text block")

    -- a tool definition and a tool result cross the message surface into the chat shape and back
    local messagedTool = ai.messages({
        model = "openai/gpt-4o",
        messages = {
            { role = "user", content = { { type = "text", text = "weather" } } },
            { role = "assistant", content = { { type = "tool_use", id = "t1", name = "lookup", input = { q = "paris" } } } },
            { role = "user", content = { { type = "tool_result", tool_use_id = "t1", content = "sunny" } } },
        },
        tools = { { name = "get_weather", description = "d", input_schema = { type = "object" } } },
        tool_choice = { type = "any" },
        max_tokens = 64,
        api_base = base,
    })
    check(seen.chat.tools[1]["function"].name == "get_weather", "messages must rename tools to the function shape")
    check(seen.chat.tools[1]["function"].parameters.type == "object", "messages must rename input_schema to parameters")
    check(seen.chat.tool_choice == "required", "messages must map any to required")
    check(seen.chat.messages[2].tool_calls[1]["function"].name == "lookup", "messages must lift tool_use into tool_calls")
    check(seen.chat.messages[3].role == "tool", "messages must split a tool result into its own turn")
    check(messagedTool.content[1].type == "tool_use", "messages must return tool_use blocks")
    check(messagedTool.content[1].input.city == "Paris", "messages must decode the tool arguments")
    check(messagedTool.stop_reason == "tool_use", "messages must map tool_calls to tool_use")

    -- the response surface takes one input instead of a conversation
    local responded = ai.responses({
        model = "openai/gpt-4o",
        instructions = "be brief",
        input = "hi",
        max_output_tokens = 64,
        api_base = base,
    })
    check(responded.object == "response" and responded.status == "completed", "responses shape mismatch")
    check(responded.output[1].content[1].type == "output_text", "responses must wrap the reply as output_text")
    check(responded.output_text == "hi there", "responses output_text mismatch")
    check(responded.usage.input_tokens == 1 and responded.usage.total_tokens == 2, "responses usage mismatch")
    check(seen.chat.messages[1].role == "system" and seen.chat.messages[1].content == "be brief", "responses must send instructions as system")
    check(seen.chat.messages[2].content == "hi", "responses must send input as a user turn")
    check(seen.chat.max_tokens == 64, "responses must rename max_output_tokens")
    check(seen.chat.input == nil and seen.chat.instructions == nil, "responses keys must not reach the wire")

    -- a structured input list carries roles and parts of its own
    ai.responses({
        model = "openai/gpt-4o",
        input = {
            { role = "user", content = { { type = "input_text", text = "describe" } } },
        },
        api_base = base,
    })
    check(seen.chat.messages[1].content[1].type == "text", "responses must convert input_text to text")

    -- streaming works through the alternative surfaces too
    local surfaceDeltas = {}
    local streamedMessage = ai.messages({
        model = "openai/gpt-4o",
        messages = { { role = "user", content = "hi" } },
        max_tokens = 64,
        api_base = base,
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            surfaceDeltas[#surfaceDeltas + 1] = content
        end
    end)
    check(table.concat(surfaceDeltas) == "Hello world", "messages stream deltas mismatch")
    check(streamedMessage.content[1].text == "Hello world", "messages stream assembly mismatch")

    -- batches upload their input, run offline, and hand the records back decoded
    local uploaded = ai.fileCreate({ model = "openai/gpt-4o", file = '{"custom_id":"a"}\n', file_name = "in.jsonl", api_base = base })
    check(uploaded.id == "file-1", "file upload mismatch")
    check(seen.files.files[1].data == '{"custom_id":"a"}\n', "file upload must carry the contents")
    check(seen.files.fields.purpose == "batch", "file upload must declare the batch purpose")

    local created = ai.batchCreate({ model = "openai/gpt-4o", input_file_id = "file-1", api_base = base })
    check(created.id == "batch-1" and created.status == "validating", "batch create mismatch")
    check(seen.batchCreate.endpoint == "/v1/chat/completions", "batch must default to the chat endpoint")
    check(seen.batchCreate.completion_window == "24h", "batch must default the completion window")

    local retrieved = ai.batchRetrieve({ model = "openai/gpt-4o", batch_id = "batch-1", api_base = base })
    check(retrieved.status == "completed", "batch retrieve mismatch")

    local listed = ai.batchList({ model = "openai/gpt-4o", api_base = base })
    check(listed.data[1].id == "batch-1", "batch list mismatch")

    local cancelled = ai.batchCancel({ model = "openai/gpt-4o", batch_id = "batch-1", api_base = base })
    check(cancelled.status == "cancelling", "batch cancel mismatch")

    local results = ai.batchResults({ model = "openai/gpt-4o", batch_id = "batch-1", api_base = base })
    check(#results.results == 2, "batch results must decode one record per line")
    check(results.results[1].custom_id == "a", "batch result record mismatch")

    -- a batch with no output yet says so rather than returning an empty result
    local pending = pcall(ai.batchResults, { model = "openai/gpt-4o", batch_id = "pending", api_base = base })
    check(not pending, "batch results must refuse a batch that has not finished")

    -- a provider that does not serve an endpoint is refused before a request is made
    local noEmbedding, embeddingErr = pcall(ai.embedding, { model = "groq/llama-3.3-70b", input = "hi", api_base = base })
    check(not noEmbedding and tostring(embeddingErr):find("does not serve embeddings"), "groq must be refused embeddings")

    local noBatch = pcall(ai.batchCreate, { model = "groq/llama-3.3-70b", input_file_id = "f", api_base = base })
    check(not noBatch, "groq must be refused batches")

    local yesEmbedding = pcall(ai.embedding, { model = "mistral/mistral-embed", input = "hi", api_base = base })
    check(yesEmbedding, "mistral must be allowed embeddings")

    -- a name or filename owns its place on a header line, so a line break is refused and a quote cannot close the field
    local wire = require("ai.wire")
    local brokenName = pcall(wire.multipart, { { name = "file", filename = "a\r\nX-Injected: 1", data = "x" } })
    check(not brokenName, "multipart must refuse a line break in a filename")
    local quoted = wire.multipart({ { name = "file", filename = 'a".png', data = "x" } })
    check(quoted:find('filename="a\\".png"', 1, true), "multipart must escape a quote in a filename")

    -- a frame that declares a length it cannot hold is a corrupt stream, not one still arriving
    local eventstream = require("ai.eventstream")
    local oversizedHeaders = string.char(0, 0, 0, 20) .. string.char(255, 255, 255, 255) .. string.char(0, 0, 0, 0) .. string.rep("x", 8)
    check(not pcall(eventstream.consume, oversizedHeaders, function() end), "event stream must refuse headers larger than the frame")
    check(
        not pcall(eventstream.consume, string.char(255, 255, 255, 255) .. string.rep("\0", 8), function() end),
        "event stream must refuse an impossible frame length"
    )

    -- a tool result has to reach the chat wire directly after the call, ahead of any text that shared its message
    local shapes = require("ai.shapes")
    local ordered = shapes.messagesToChat({
        model = "m",
        messages = {
            { role = "assistant", content = { { type = "tool_use", id = "t1", name = "f", input = {} } } },
            { role = "user", content = { { type = "tool_result", tool_use_id = "t1", content = "r" }, { type = "text", text = "and now" } } },
        },
    })
    check(ordered.messages[2].role == "tool", "the tool result must follow the call directly")
    check(ordered.messages[3].role == "user", "text sharing the message must come after the tool result")

    -- the response surface declares a function flat, so it is rebuilt into the nested chat shape
    local rebuilt = shapes.responsesToChat({
        model = "m",
        input = "hi",
        tools = { { type = "function", name = "lookup", parameters = { type = "object" } } },
    })
    check(rebuilt.tools[1]["function"].name == "lookup", "responses must nest a flat tool definition")
    check(rebuilt.tools[1]["function"].parameters.type == "object", "responses must carry the tool parameters over")

    -- rerank is a plain post for most providers
    local ranked = ai.rerank({ model = "huggingface/bge-reranker", query = "q", documents = { "a" }, api_base = base })
    check(ranked.results[1].relevance_score == 0.7, "rerank mismatch")
    check(seen.rerank.query == "q", "rerank must send the query")

    -- the qwen family names it in the plural and serves it from a compatible-api sibling of the chat base
    ai.rerank({ model = "dashscope/gte-rerank", query = "q", documents = { "a" }, api_base = base })
    check(seen.reranks ~= nil, "the qwen family must call reranks in the plural")

    ai.rerank({ model = "dashscope/gte-rerank", query = "q", documents = { "a" }, api_base = base .. "/compatible-mode/v1" })
    check(seen.qwenRerank == "/compatible-api/v1/reranks", "the qwen family must swap compatible-mode for compatible-api, got " .. tostring(seen.qwenRerank))

    -- the registry covers every published provider slug
    local slugs = ai.providers()
    check(#slugs > 100, "expected the full provider registry, got " .. #slugs)

    print("ai mock ok")
end)
