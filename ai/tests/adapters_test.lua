-- mock-server coverage for the adapters the wire test does not reach: replicate, watsonx, elevenlabs, deepgram, the dedicated image providers, and the file helpers.
-- it needs no network and no api keys.
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local fs = require("fs")
local http = require("http")
local ai = require("ai")

local port = 39902
local base = "http://127.0.0.1:" .. port
local scratch = assert(os.getenv("VARN_TEST_DIR"), "VARN_TEST_DIR is not set")

local seen = {}
local app = http.createApp()

app:post("/models/:owner/:name/predictions", function(ctx)
    seen.replicate = { body = ctx:body(), prefer = ctx.request.headers["Prefer"] or ctx.request.headers["prefer"] }
    ctx:json({ id = "pred1", status = "succeeded", output = { "replicate ", "says hi" } })
end)

app:post("/identity/token", function(ctx)
    seen.iam = (seen.iam or 0) + 1
    ctx:json({ access_token = "iam-token", expires_in = 3600 })
end)

app:post("/ml/v1/text/chat", function(ctx)
    seen.watsonx = { body = ctx:body(), auth = ctx.request.headers["Authorization"] or ctx.request.headers["authorization"], query = ctx.request.query }
    ctx:json({
        id = "wx1",
        model_id = "ibm/granite",
        choices = { { index = 0, message = { role = "assistant", content = "watsonx says hi" }, finish_reason = "stop" } },
        usage = { prompt_tokens = 2, completion_tokens = 3, total_tokens = 5 },
    })
end)

app:post("/v1/text-to-speech/:voice", function(ctx)
    seen.eleven = { body = ctx:body(), voice = ctx.params.voice, key = ctx.request.headers["xi-api-key"] }
    ctx:send("ELEVENAUDIO")
end)

app:post("/v1/speech-to-text", function(ctx)
    seen.elevenStt = ctx:body()
    ctx:json({ text = "eleven transcript" })
end)

app:post("/listen", function(ctx)
    seen.deepgram = { body = ctx:body(), query = ctx.query, auth = ctx.request.headers["Authorization"] or ctx.request.headers["authorization"] }
    ctx:json({ results = { channels = { { alternatives = { { transcript = "deepgram transcript" } } } } } })
end)

app:post("/fal-ai/flux", function(ctx)
    seen.fal = { body = ctx:body(), auth = ctx.request.headers["Authorization"] or ctx.request.headers["authorization"] }
    ctx:json({ images = { { url = base .. "/asset.png" } } })
end)

app:post("/v2beta/stable-image/generate/core", function(ctx)
    seen.stability = ctx:body()
    ctx:json({ image = "c3RhYmxl" })
end)

app:get("/asset.png", function(ctx)
    ctx:send("PNGBYTES")
end)

app:post("/openai/deployments/:deployment/audio/transcriptions", function(ctx)
    seen.azureStt = { body = ctx:body(), deployment = ctx.params.deployment }
    ctx:json({ text = "azure transcript" })
end)

app:post("/openai/deployments/:deployment/audio/speech", function(ctx)
    seen.azureTts = ctx:body()
    ctx:send("AZUREAUDIO")
end)

app:post("/openai/deployments/:deployment/chat/completions", function(ctx)
    seen.azureChat = { body = ctx:body(), deployment = ctx.params.deployment, query = ctx.query }
    local sse = ctx:sse()
    sse:send(json.encode({ id = "azs1", model = "gpt-4o", choices = { { index = 0, delta = { role = "assistant" } } } }))
    sse:send(json.encode({ id = "azs1", model = "gpt-4o", choices = { { index = 0, delta = { content = "azure " } } } }))
    sse:send(json.encode({ id = "azs1", model = "gpt-4o", choices = { { index = 0, delta = { content = "streams" }, finish_reason = "stop" } } }))
    sse:send("[DONE]")
    sse:close()
end)

app:post("/openai/deployments/:deployment/moderations", function(ctx)
    seen.azureModeration = ctx:body()
    ctx:json({ id = "azm1", results = { { flagged = true } } })
end)

app:post("/openai/batches", function(ctx)
    seen.azureBatch = { body = ctx:body(), query = ctx.query }
    ctx:json({ id = "azbatch-1", object = "batch", status = "validating" })
end)

app:post("/model/:model/invoke", function(ctx)
    seen.bedrockInvoke = { body = ctx:body(), model = ctx.params.model }
    if ctx.params.model:find("^cohere%.") then
        ctx:json({ embeddings = { { 0.7, 0.8 } } })
        return
    end
    ctx:json({ embedding = { 0.4, 0.5, 0.6 }, inputTextTokenCount = 3 })
end)

app:post("/rerank", function(ctx)
    seen.bedrockRerank = ctx:body()
    ctx:json({ results = { { index = 1, relevanceScore = 0.92 }, { index = 0, relevanceScore = 0.11 } } })
end)

app:post("/v1beta/models/:model", function(ctx)
    seen.geminiEmbed = { body = ctx:body(), model = ctx.params.model }
    ctx:json({ embeddings = { { values = { 0.11, 0.22 } }, { values = { 0.33, 0.44 } } } })
end)

app:post("/v1/projects/:project/locations/:location/publishers/google/models/:model", function(ctx)
    seen.vertex = { body = ctx:body(), project = ctx.params.project, location = ctx.params.location, model = ctx.params.model }
    ctx:json({ predictions = { { bytesBase64Encoded = "aW1hZ2U=" } } })
end)

app:post("/fal-ai/llm", function(ctx)
    seen.falChat = ctx:body()
    ctx:json({ output = "fal says hi" })
end)

app:post("/fal-ai/llm/stream", function(ctx)
    local sse = ctx:sse()
    -- fal resends the whole output so far, so the adapter has to send only what is new
    sse:send(json.encode({ output = "fal" }))
    sse:send(json.encode({ output = "fal says" }))
    sse:send(json.encode({ output = "fal says hi" }))
    sse:close()
end)

app:post("/predictions", function(ctx)
    seen.replicateStream = ctx:body()
    ctx:json({ id = "pred2", status = "starting", urls = { stream = base .. "/stream/pred2" } })
end)

app:get("/stream/pred2", function(ctx)
    local sse = ctx:sse()
    sse:send("output", "replicate ")
    sse:send("output", "streams")
    sse:send("done", "{}")
    sse:close()
end)

app:post("/ml/v1/text/chat_stream", function(ctx)
    seen.watsonxStream = ctx:body()
    local sse = ctx:sse()
    sse:send(json.encode({ id = "wxs1", choices = { { index = 0, delta = { role = "assistant" } } } }))
    sse:send(json.encode({ id = "wxs1", choices = { { index = 0, delta = { content = "watsonx " } } } }))
    sse:send(json.encode({ id = "wxs1", choices = { { index = 0, delta = { content = "streams" }, finish_reason = "stop" } } }))
    sse:close()
end)

-- builds one aws event stream frame, whose prelude carries the two lengths and whose headers are length-prefixed and typed
local function awsFrame(eventType, payload)
    local function uint32(n)
        return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
    end

    local function header(name, value)
        return string.char(#name) .. name .. string.char(7) .. string.char(math.floor(#value / 256), #value % 256) .. value
    end

    local headers = header(":event-type", eventType) .. header(":message-type", "event")
    local total = 12 + #headers + #payload + 4

    return uint32(total) .. uint32(#headers) .. uint32(0) .. headers .. payload .. uint32(0)
end

app:post("/model/:model/converse-stream", function(ctx)
    seen.bedrockStream = { body = ctx:body(), auth = ctx.request.headers["Authorization"] or ctx.request.headers["authorization"] }

    local frames = {
        awsFrame("messageStart", json.encode({ role = "assistant" })),
        awsFrame("contentBlockDelta", json.encode({ contentBlockIndex = 0, delta = { text = "bedrock " } })),
        awsFrame("contentBlockDelta", json.encode({ contentBlockIndex = 0, delta = { text = "streams" } })),
        awsFrame("contentBlockStart", json.encode({ contentBlockIndex = 1, start = { toolUse = { toolUseId = "tu9", name = "lookup" } } })),
        awsFrame("contentBlockDelta", json.encode({ contentBlockIndex = 1, delta = { toolUse = { input = '{"q":' } } })),
        awsFrame("contentBlockDelta", json.encode({ contentBlockIndex = 1, delta = { toolUse = { input = '"rio"}' } } })),
        awsFrame("messageStop", json.encode({ stopReason = "tool_use" })),
        awsFrame("metadata", json.encode({ usage = { inputTokens = 5, outputTokens = 6, totalTokens = 11 } })),
    }

    ctx:header("Content-Type", "application/vnd.amazon.eventstream")
    ctx:send(table.concat(frames))
end)

app:post("/v2/chat", function(ctx)
    local body = ctx:body()
    seen.cohereChat = body

    if not body.stream then
        ctx:json({
            id = "co2",
            message = { role = "assistant", content = { { type = "text", text = "cohere replies" } } },
            finish_reason = "COMPLETE",
            usage = { tokens = { input_tokens = 2, output_tokens = 2 } },
        })
        return
    end

    local sse = ctx:sse()
    local function event(payload)
        sse:send(json.encode(payload))
    end

    event({ type = "message-start", id = "cos1" })
    event({ type = "content-delta", delta = { message = { content = { text = "cohere " } } } })
    event({ type = "content-delta", delta = { message = { content = { text = "streams" } } } })
    local function toolEvent(kind, call)
        event({ type = kind, delta = { message = { tool_calls = call } } })
    end

    toolEvent("tool-call-start", { id = "ct1", ["function"] = { name = "lookup" } })
    toolEvent("tool-call-delta", { ["function"] = { arguments = '{"q":' } })
    toolEvent("tool-call-delta", { ["function"] = { arguments = '"sp"}' } })
    event({ type = "message-end", delta = { finish_reason = "TOOL_CALL", usage = { tokens = { input_tokens = 3, output_tokens = 7 } } } })
    sse:close()
end)

app:post("/v2/embed", function(ctx)
    seen.cohereEmbed = ctx:body()
    ctx:json({ embeddings = { float = { { 0.1, 0.2 }, { 0.3, 0.4 } } }, meta = { tokens = { input_tokens = 4, output_tokens = 0 } } })
end)

app:post("/v2/rerank", function(ctx)
    seen.cohereRerank = ctx:body()
    ctx:json({ results = { { index = 1, relevance_score = 0.88 } } })
end)

app:post("/openai/deployments/:deployment/embeddings", function(ctx)
    seen.azureEmbed = { body = ctx:body(), deployment = ctx.params.deployment }
    ctx:json({ object = "list", data = { { object = "embedding", index = 0, embedding = { 0.9, 0.8 } } } })
end)

app:post("/openai/deployments/:deployment/images/generations", function(ctx)
    seen.azureImage = { body = ctx:body(), deployment = ctx.params.deployment }
    ctx:json({ created = 1, data = { { b64_json = "YXp1cmU=" } } })
end)

app:post("/openai/files", function(ctx)
    seen.azureFile = ctx:body()
    ctx:json({ id = "azfile-1", object = "file", purpose = "batch" })
end)

app:get("/openai/batches", function(ctx)
    seen.azureBatchList = ctx.query
    ctx:json({ object = "list", data = { { id = "azbatch-1", status = "completed" } } })
end)

app:get("/openai/batches/:id", function(ctx)
    ctx:json({ id = ctx.params.id, object = "batch", status = "completed", output_file_id = "azfile-out" })
end)

app:post("/openai/batches/:id/cancel", function(ctx)
    ctx:json({ id = ctx.params.id, object = "batch", status = "cancelling" })
end)

app:get("/openai/files/:id/content", function(ctx)
    ctx:send('{"custom_id":"x"}\n{"custom_id":"y"}\n')
end)

app:post("/ml/v1/text/embeddings", function(ctx)
    seen.watsonxEmbed = ctx:body()
    ctx:json({ results = { { embedding = { 0.5, 0.6 } }, { embedding = { 0.7, 0.8 } } } })
end)

app:post("/v1/messages/batches", function(ctx)
    seen.anthropicBatch = ctx:body()
    ctx:json({ id = "msgbatch_1", type = "message_batch", processing_status = "in_progress" })
end)

app:get("/v1/messages/batches", function(ctx)
    seen.anthropicBatchList = ctx.query
    ctx:json({ data = { { id = "msgbatch_1", processing_status = "ended" } } })
end)

app:get("/v1/messages/batches/:id", function(ctx)
    if ctx.params.id == "running" then
        ctx:json({ id = "running", processing_status = "in_progress" })
        return
    end
    ctx:json({ id = ctx.params.id, processing_status = "ended", results_url = base .. "/v1/messages/batches/" .. ctx.params.id .. "/results" })
end)

app:post("/v1/messages/batches/:id/cancel", function(ctx)
    ctx:json({ id = ctx.params.id, processing_status = "canceling" })
end)

app:get("/v1/messages/batches/:id/results", function(ctx)
    ctx:send('{"custom_id":"a","result":{"type":"succeeded"}}\n{"custom_id":"b","result":{"type":"errored"}}\n')
end)

app:post("/v1/flux-pro", function(ctx)
    seen.bfl = { body = ctx:body(), key = ctx.request.headers["x-key"] }
    ctx:json({ id = "bfl1", polling_url = base .. "/bfl/poll" })
end)

app:get("/bfl/poll", function(ctx)
    seen.bflPolls = (seen.bflPolls or 0) + 1
    if seen.bflPolls < 2 then
        ctx:json({ status = "Pending" })
        return
    end
    ctx:json({ status = "Ready", result = { sample = base .. "/asset.png" } })
end)

app:listen({ host = "127.0.0.1", port = port })

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

async.run(function()
    -- replicate has no conversation wire, so the turns are rendered into one prompt and the call waits inline
    local replicate = ai.completion({
        model = "replicate/meta/llama-3-8b",
        messages = {
            { role = "system", content = "be brief" },
            { role = "user", content = "hi" },
        },
        max_tokens = 32,
        api_base = base,
        api_key = "r8-test",
    })
    check(replicate.choices[1].message.content == "replicate says hi", "replicate must join the output chunks")
    check(replicate.choices[1].finish_reason == "stop", "replicate finish mismatch")
    check(seen.replicate.prefer == "wait", "replicate must ask the api to wait for the prediction")
    check(seen.replicate.body.input.system_prompt == "be brief", "replicate must split the system prompt out")
    check(seen.replicate.body.input.prompt:find("User: hi"), "replicate must render the user turn")
    check(seen.replicate.body.input.prompt:find("Assistant:$"), "replicate must leave the reply open")
    check(seen.replicate.body.input.max_tokens == 32, "replicate max_tokens mismatch")

    -- watsonx exchanges the api key for an iam token once and reuses it
    local watsonx = ai.completion({
        model = "watsonx/ibm/granite-3-8b-instruct",
        messages = { { role = "user", content = "hi" } },
        project_id = "proj-1",
        api_base = base,
        iam_url = base .. "/identity/token",
        api_key = "wx-key",
    })
    check(watsonx.choices[1].message.content == "watsonx says hi", "watsonx content mismatch")
    check(seen.watsonx.auth == "Bearer iam-token", "watsonx must send the exchanged iam token")
    check(seen.watsonx.body.model_id == "ibm/granite-3-8b-instruct", "watsonx must rename model to model_id")
    check(seen.watsonx.body.project_id == "proj-1", "watsonx must carry the project id")
    check(seen.watsonx.query.version, "watsonx must send the api version")

    ai.completion({
        model = "watsonx/ibm/granite-3-8b-instruct",
        messages = { { role = "user", content = "again" } },
        project_id = "proj-1",
        api_base = base,
        iam_url = base .. "/identity/token",
        api_key = "wx-key",
    })
    check(seen.iam == 1, "watsonx must cache the iam token instead of exchanging it per call")

    -- watsonx says which setting is missing rather than letting the api reject the call
    local noProject = pcall(ai.completion, {
        model = "watsonx/ibm/granite",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        iam_url = base .. "/identity/token",
        api_key = "wx-key",
    })
    check(not noProject, "watsonx must demand a project id")

    -- elevenlabs addresses the voice in the path and answers with raw audio
    local audio = ai.speech({
        model = "elevenlabs/eleven_multilingual_v2",
        input = "olá",
        voice = "voice-123",
        api_base = base,
        api_key = "xi-test",
    })
    check(audio == "ELEVENAUDIO", "elevenlabs must return the raw audio bytes")
    check(seen.eleven.voice == "voice-123", "elevenlabs must put the voice in the path")
    check(seen.eleven.key == "xi-test", "elevenlabs must authenticate with xi-api-key")
    check(seen.eleven.body.model_id == "eleven_multilingual_v2", "elevenlabs model mismatch")
    check(seen.eleven.body.text == "olá", "elevenlabs must send the input as text")

    local noVoice = pcall(ai.speech, { model = "elevenlabs/eleven_multilingual_v2", input = "hi", api_base = base })
    check(not noVoice, "elevenlabs must demand a voice")

    local elevenText = ai.transcription({
        model = "elevenlabs/scribe_v1",
        file = "MP3BYTES",
        file_name = "a.mp3",
        api_base = base,
        api_key = "xi-test",
    })
    check(elevenText.text == "eleven transcript", "elevenlabs transcription mismatch")
    check(seen.elevenStt.files[1].data == "MP3BYTES", "elevenlabs must upload the audio")
    check(seen.elevenStt.fields.model_id == "scribe_v1", "elevenlabs must send model_id")

    -- deepgram takes the audio as the body and its options on the query string
    local deepgram = ai.transcription({
        model = "deepgram/nova-3",
        file = "WAVBYTES",
        smart_format = true,
        api_base = base,
        api_key = "dg-test",
    })
    check(deepgram.text == "deepgram transcript", "deepgram must lift the transcript out")
    check(seen.deepgram.auth == "Token dg-test", "deepgram must use its token scheme")
    check(seen.deepgram.query.model == "nova-3", "deepgram must select the model on the query")
    check(seen.deepgram.query.smart_format == "true", "deepgram must pass options on the query")

    -- the dedicated image providers normalise onto the openai image shape
    local fal = ai.imageGeneration({ model = "fal_ai/fal-ai/flux", prompt = "a cat", api_base = base, api_key = "fal-key" })
    check(fal.data[1].url == base .. "/asset.png", "fal image url mismatch")
    check(seen.fal.auth == "Key fal-key", "fal must use its key scheme")
    check(seen.fal.body.prompt == "a cat", "fal prompt mismatch")

    local stability = ai.imageGeneration({ model = "stability/core", prompt = "a dog", api_base = base, api_key = "sk-test" })
    check(stability.data[1].b64_json == "c3RhYmxl", "stability image mismatch")
    check(seen.stability.fields.prompt == "a dog", "stability must post the prompt as multipart")

    -- saveImage handles both the inline and the downloaded form
    local inlinePath = scratch .. "/inline.png"
    ai.saveImage({ b64_json = "aGVsbG8=" }, inlinePath)
    check(fs.readFile(inlinePath):await() == "hello", "saveImage must decode base64")

    local downloadedPath = scratch .. "/downloaded.png"
    ai.saveImage({ url = base .. "/asset.png" }, downloadedPath)
    check(fs.readFile(downloadedPath):await() == "PNGBYTES", "saveImage must download a url")

    local audioPath = scratch .. "/speech.mp3"
    ai.saveAudio(audio, audioPath)
    check(fs.readFile(audioPath):await() == "ELEVENAUDIO", "saveAudio must write the bytes")

    -- a provider that cannot serve an endpoint says so instead of sending a request that would fail
    local noImage = pcall(ai.imageGeneration, { model = "anthropic/claude-sonnet-4-5", prompt = "x", api_base = base })
    check(not noImage, "anthropic must refuse image generation")

    -- azure serves audio, moderation and batches under the same deployment-scoped path
    local azureText = ai.transcription({
        model = "azure/whisper-deploy",
        file = "WAVBYTES",
        api_base = base,
        api_key = "az",
    })
    check(azureText.text == "azure transcript", "azure transcription mismatch")
    check(seen.azureStt.deployment == "whisper-deploy", "azure transcription must address the deployment")
    check(seen.azureStt.body.files[1].data == "WAVBYTES", "azure must upload the audio")

    local azureAudio = ai.speech({ model = "azure/tts-deploy", input = "hi", voice = "alloy", api_base = base, api_key = "az" })
    check(azureAudio == "AZUREAUDIO", "azure speech must return raw bytes")
    check(seen.azureTts.model == nil, "azure must not repeat the model in the body")

    local azureModeration = ai.moderation({ model = "azure/mod-deploy", input = "hi", api_base = base, api_key = "az" })
    check(azureModeration.results[1].flagged == true, "azure moderation mismatch")

    -- azure batches sit beside the deployments rather than under one
    local azureBatch = ai.batchCreate({ model = "azure/gpt-4o", input_file_id = "file-1", api_base = base, api_key = "az" })
    check(azureBatch.id == "azbatch-1", "azure batch create mismatch")
    check(seen.azureBatch.body.endpoint == "/chat/completions", "azure batch endpoint mismatch")
    check(seen.azureBatch.query["api-version"], "azure batch must send the api version")

    -- bedrock embeddings go one signed invoke per input, and the two model families name their fields differently
    local titan = ai.embedding({
        model = "bedrock/amazon.titan-embed-text-v2:0",
        input = { "one", "two" },
        api_base = base,
        api_key = "secret",
        aws_access_key_id = "AKIDEXAMPLE",
        aws_region_name = "us-east-1",
    })
    check(#titan.data == 2, "bedrock must embed each input")
    check(titan.data[1].embedding[3] == 0.6, "bedrock titan embedding mismatch")
    check(titan.usage.total_tokens == 6, "bedrock must sum the token counts")
    check(seen.bedrockInvoke.body.inputText == "two", "bedrock titan must send inputText")

    local cohereEmbed = ai.embedding({
        model = "bedrock/cohere.embed-english-v3",
        input = "one",
        api_base = base,
        api_key = "secret",
        aws_access_key_id = "AKIDEXAMPLE",
        aws_region_name = "us-east-1",
    })
    check(cohereEmbed.data[1].embedding[2] == 0.8, "bedrock cohere embedding mismatch")
    check(seen.bedrockInvoke.body.texts[1] == "one", "bedrock cohere must send texts")

    local reranked = ai.rerank({
        model = "bedrock/amazon.rerank-v1:0",
        query = "cats",
        documents = { "dogs", "cats" },
        api_base = base,
        api_key = "secret",
        aws_access_key_id = "AKIDEXAMPLE",
        aws_region_name = "us-east-1",
    })
    check(reranked.results[1].index == 1 and reranked.results[1].relevance_score == 0.92, "bedrock rerank mismatch")
    check(seen.bedrockRerank.sources[1].textDocument.text == "dogs", "bedrock rerank must send the documents")
    check(
        seen.bedrockRerank.rerankingConfiguration.bedrockRerankingConfiguration.modelConfiguration.modelArn:find("us%-east%-1"),
        "bedrock rerank must build the model arn from the region"
    )

    -- vertex addresses a project and a region, and its image models answer a predict call
    local vertexImage = ai.imageGeneration({
        model = "vertex_ai/imagen-3.0-generate-002",
        prompt = "a cat",
        api_base = base,
        api_key = "token",
        vertex_project = "proj",
        vertex_location = "us-central1",
    })
    check(vertexImage.data[1].b64_json == "aW1hZ2U=", "vertex image mismatch")
    check(seen.vertex.project == "proj" and seen.vertex.location == "us-central1", "vertex must address the project and region")
    check(seen.vertex.model == "imagen-3.0-generate-002:predict", "vertex image must call predict")
    check(seen.vertex.body.instances[1].prompt == "a cat", "vertex prompt mismatch")

    -- vertex says what is missing rather than building an endpoint it cannot address
    local noProjectVertex = pcall(ai.completion, {
        model = "vertex_ai/gemini-2.5-pro",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
    })
    check(not noProjectVertex, "vertex must demand a project and location")

    -- fal also hosts language models, which take the conversation as one prompt
    local falChat = ai.completion({
        model = "fal_ai/fal-ai/llm",
        messages = {
            { role = "system", content = "be brief" },
            { role = "user", content = "hi" },
        },
        api_base = base,
        api_key = "fal-key",
    })
    check(falChat.choices[1].message.content == "fal says hi", "fal chat mismatch")
    check(seen.falChat.system_prompt == "be brief", "fal must split the system prompt out")
    check(seen.falChat.prompt == "hi", "fal prompt mismatch")

    -- bedrock streams over the aws binary event protocol, which the client decodes frame by frame
    local bedrockDeltas = {}
    local bedrockStream = ai.completion({
        model = "bedrock/anthropic.claude-sonnet-4-5-v1:0",
        messages = { { role = "user", content = "hi" } },
        max_tokens = 64,
        api_base = base,
        api_key = "secret",
        aws_access_key_id = "AKIDEXAMPLE",
        aws_region_name = "us-east-1",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            bedrockDeltas[#bedrockDeltas + 1] = content
        end
    end)
    check(table.concat(bedrockDeltas) == "bedrock streams", "bedrock stream deltas mismatch")
    check(bedrockStream.choices[1].message.content == "bedrock streams", "bedrock stream assembly mismatch")
    check(bedrockStream.choices[1].finish_reason == "tool_calls", "bedrock stream must map tool_use")
    check(bedrockStream.usage.total_tokens == 11, "bedrock stream usage mismatch")
    local bedrockCall = bedrockStream.choices[1].message.tool_calls[1]
    check(bedrockCall.id == "tu9" and bedrockCall["function"].name == "lookup", "bedrock stream tool mismatch")
    check(bedrockCall["function"].arguments == '{"q":"rio"}', "bedrock must join the tool input fragments")
    check(seen.bedrockStream.auth:find("^AWS4%-HMAC%-SHA256"), "bedrock stream must be signed")

    -- watsonx streams from a sibling of its chat endpoint
    local watsonxDeltas = {}
    local watsonxStream = ai.completion({
        model = "watsonx/ibm/granite-3-8b-instruct",
        messages = { { role = "user", content = "hi" } },
        project_id = "proj-1",
        api_base = base,
        iam_url = base .. "/identity/token",
        api_key = "wx-key",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            watsonxDeltas[#watsonxDeltas + 1] = content
        end
    end)
    check(table.concat(watsonxDeltas) == "watsonx streams", "watsonx stream deltas mismatch")
    check(watsonxStream.choices[1].message.content == "watsonx streams", "watsonx stream assembly mismatch")
    check(watsonxStream.choices[1].finish_reason == "stop", "watsonx stream finish mismatch")
    check(seen.watsonxStream.model_id == "ibm/granite-3-8b-instruct", "watsonx stream model mismatch")

    -- replicate answers with a url to follow rather than the tokens themselves
    local replicateDeltas = {}
    local replicateStream = ai.completion({
        model = "replicate/meta/llama-3-8b:abc123",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "r8-test",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            replicateDeltas[#replicateDeltas + 1] = content
        end
    end)
    check(table.concat(replicateDeltas) == "replicate streams", "replicate stream deltas mismatch")
    check(replicateStream.choices[1].message.content == "replicate streams", "replicate stream assembly mismatch")
    check(seen.replicateStream.stream == true, "replicate must ask for a stream")
    check(seen.replicateStream.version == "abc123", "replicate must pin the version from the model name")

    -- fal resends the whole output each event, so the adapter must emit only the new part
    local falDeltas = {}
    local falStream = ai.completion({
        model = "fal_ai/fal-ai/llm",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "fal-key",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            falDeltas[#falDeltas + 1] = content
        end
    end)
    check(table.concat(falDeltas) == "fal says hi", "fal stream deltas mismatch")
    check(#falDeltas == 3, "fal must emit one delta per event, got " .. #falDeltas)
    check(falStream.choices[1].message.content == "fal says hi", "fal stream assembly mismatch")

    -- cohere streaming builds its reply from a protocol of its own, with tool arguments arriving in fragments
    local cohereDeltas = {}
    local cohereStream = ai.completion({
        model = "cohere/command-a",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "co",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            cohereDeltas[#cohereDeltas + 1] = content
        end
    end)
    check(table.concat(cohereDeltas) == "cohere streams", "cohere stream deltas mismatch")
    check(cohereStream.choices[1].message.content == "cohere streams", "cohere stream assembly mismatch")
    check(cohereStream.choices[1].finish_reason == "tool_calls", "cohere must map TOOL_CALL to tool_calls")
    local cohereCall = cohereStream.choices[1].message.tool_calls[1]
    check(cohereCall.id == "ct1" and cohereCall["function"].name == "lookup", "cohere stream tool mismatch")
    check(cohereCall["function"].arguments == '{"q":"sp"}', "cohere must join the tool argument fragments")
    check(cohereStream.usage.total_tokens == 10, "cohere stream usage mismatch")

    local cohereEmbedded = ai.embedding({ model = "cohere/embed-v4", input = { "a", "b" }, api_base = base, api_key = "co" })
    check(#cohereEmbedded.data == 2 and cohereEmbedded.data[2].embedding[1] == 0.3, "cohere embedding mismatch")
    check(seen.cohereEmbed.texts[2] == "b", "cohere must send the inputs as texts")
    check(seen.cohereEmbed.input_type == "search_document", "cohere must default the input type")

    local cohereRanked = ai.rerank({ model = "cohere/rerank-v3.5", query = "q", documents = { "a", "b" }, top_n = 1, api_base = base, api_key = "co" })
    check(cohereRanked.results[1].index == 1, "cohere rerank mismatch")
    check(seen.cohereRerank.top_n == 1, "cohere rerank must carry top_n")

    -- azure serves embeddings and images from the deployment path too
    local azureEmbedded = ai.embedding({ model = "azure/embed-deploy", input = "hi", api_base = base, api_key = "az" })
    check(azureEmbedded.data[1].embedding[1] == 0.9, "azure embedding mismatch")
    check(seen.azureEmbed.deployment == "embed-deploy", "azure embedding must address the deployment")
    check(seen.azureEmbed.body.model == nil, "azure embedding must not repeat the model")

    local azureImage = ai.imageGeneration({ model = "azure/dalle-deploy", prompt = "a cat", api_base = base, api_key = "az" })
    check(azureImage.data[1].b64_json == "YXp1cmU=", "azure image mismatch")
    check(seen.azureImage.body.prompt == "a cat", "azure image prompt mismatch")

    local azureDeltas = {}
    local azureStream = ai.completion({
        model = "azure/gpt-4o",
        messages = { { role = "user", content = "hi" } },
        api_base = base,
        api_key = "az",
    }, function(chunk)
        local content = chunk.choices[1].delta.content
        if content then
            azureDeltas[#azureDeltas + 1] = content
        end
    end)
    check(table.concat(azureDeltas) == "azure streams", "azure stream deltas mismatch")
    check(azureStream.choices[1].message.content == "azure streams", "azure stream assembly mismatch")
    check(azureStream.choices[1].finish_reason == "stop", "azure stream finish mismatch")
    check(seen.azureChat.deployment == "gpt-4o", "azure stream must address the deployment")
    check(seen.azureChat.body.stream == true, "azure stream must ask for a stream")
    check(seen.azureChat.query["api-version"], "azure stream must send the api version")

    local azureFile = ai.fileCreate({ model = "azure/gpt-4o", file = '{"custom_id":"a"}\n', file_name = "in.jsonl", api_base = base, api_key = "az" })
    check(azureFile.id == "azfile-1", "azure file upload mismatch")
    check(seen.azureFile.files[1].data == '{"custom_id":"a"}\n', "azure file upload must carry the contents")
    check(seen.azureFile.fields.purpose == "batch", "azure file upload must declare the batch purpose")

    -- gemini embeds through a batch call and unwraps the values onto the openai shape
    local geminiEmbedded = ai.embedding({ model = "gemini/text-embedding-004", input = { "a", "b" }, api_base = base, api_key = "gk" })
    check(#geminiEmbedded.data == 2 and geminiEmbedded.data[2].embedding[1] == 0.33, "gemini embedding mismatch")
    check(seen.geminiEmbed.model == "text-embedding-004:batchEmbedContents", "gemini embedding must call batchEmbedContents")
    check(seen.geminiEmbed.body.requests[1].content.parts[1].text == "a", "gemini embedding must wrap each input")
    check(seen.geminiEmbed.body.requests[1].model == "models/text-embedding-004", "gemini embedding must qualify the model")

    local azureResults = ai.batchResults({ model = "azure/gpt-4o", batch_id = "azb1", api_base = base, api_key = "az" })
    check(#azureResults.results == 2 and azureResults.results[2].custom_id == "y", "azure batch results mismatch")

    -- watsonx embeddings rename the input and unwrap the results
    local watsonxEmbedded = ai.embedding({
        model = "watsonx/ibm/slate-30m",
        input = { "a", "b" },
        project_id = "proj-1",
        api_base = base,
        iam_url = base .. "/identity/token",
        api_key = "wx-key",
    })
    check(#watsonxEmbedded.data == 2 and watsonxEmbedded.data[1].embedding[1] == 0.5, "watsonx embedding mismatch")
    check(seen.watsonxEmbed.inputs[2] == "b", "watsonx must rename input to inputs")
    check(seen.watsonxEmbed.input == nil, "watsonx must not leave the openai key on the wire")
    check(seen.watsonxEmbed.project_id == "proj-1", "watsonx embedding must carry the project")

    -- anthropic takes its batch requests inline rather than through an uploaded file
    local anthropicBatch = ai.batchCreate({
        model = "anthropic/claude-haiku-4-5",
        requests = {
            { custom_id = "a", params = { messages = { { role = "user", content = "hi" } }, max_tokens = 16 } },
        },
        api_base = base,
        api_key = "ak",
    })
    check(anthropicBatch.id == "msgbatch_1", "anthropic batch create mismatch")
    check(seen.anthropicBatch.requests[1].custom_id == "a", "anthropic batch must carry the custom id")
    check(seen.anthropicBatch.requests[1].params.max_tokens == 16, "anthropic batch must build the params")
    check(seen.anthropicBatch.requests[1].params.messages[1].content[1].type == "text", "anthropic batch must send content blocks")

    local anthropicResults = ai.batchResults({ model = "anthropic/claude-haiku-4-5", batch_id = "done", api_base = base, api_key = "ak" })
    check(#anthropicResults.results == 2, "anthropic batch results mismatch")
    check(anthropicResults.results[1].result.type == "succeeded", "anthropic batch record mismatch")

    local anthropicPending = pcall(ai.batchResults, { model = "anthropic/claude-haiku-4-5", batch_id = "running", api_base = base, api_key = "ak" })
    check(not anthropicPending, "anthropic must refuse results for a batch still running")

    local anthropicRetrieved = ai.batchRetrieve({ model = "anthropic/claude-haiku-4-5", batch_id = "msgbatch_1", api_base = base, api_key = "ak" })
    check(anthropicRetrieved.processing_status == "ended", "anthropic batch retrieve mismatch")

    local azureRetrieved = ai.batchRetrieve({ model = "azure/gpt-4o", batch_id = "azbatch-1", api_base = base, api_key = "az" })
    check(azureRetrieved.status == "completed", "azure batch retrieve mismatch")

    local anthropicListed = ai.batchList({ model = "anthropic/claude-haiku-4-5", limit = 5, api_base = base, api_key = "ak" })
    check(anthropicListed.data[1].id == "msgbatch_1", "anthropic batch list mismatch")
    check(seen.anthropicBatchList.limit == "5", "anthropic batch list must pass the limit")

    local anthropicCancelled = ai.batchCancel({ model = "anthropic/claude-haiku-4-5", batch_id = "msgbatch_1", api_base = base, api_key = "ak" })
    check(anthropicCancelled.processing_status == "canceling", "anthropic batch cancel mismatch")

    local azureListed = ai.batchList({ model = "azure/gpt-4o", limit = 3, api_base = base, api_key = "az" })
    check(azureListed.data[1].id == "azbatch-1", "azure batch list mismatch")
    check(seen.azureBatchList.limit == "3", "azure batch list must pass the limit")

    local azureCancelled = ai.batchCancel({ model = "azure/gpt-4o", batch_id = "azbatch-1", api_base = base, api_key = "az" })
    check(azureCancelled.status == "cancelling", "azure batch cancel mismatch")

    -- black forest labs answers with a job to poll rather than the finished image
    local bflImage = ai.imageGeneration({ model = "black_forest_labs/flux-pro", prompt = "a fox", api_base = base, api_key = "bfl" })
    check(bflImage.data[1].url == base .. "/asset.png", "bfl image mismatch")
    check(seen.bfl.key == "bfl", "bfl must authenticate with its own header")
    check(seen.bfl.body.prompt == "a fox", "bfl prompt mismatch")
    check(seen.bflPolls >= 2, "bfl must keep polling until the job is ready")

    print("ai adapters ok")
end)
