-- deterministic mock-server coverage for the ai adapter reaching what the basic mock_test does not, covering openai embed/image, anthropic streaming (text, reasoning, tool), the whole gemini adapter (generate, stream, image), every elevenlabs audio method, and saveImage over a url.
-- it needs no network and no api keys.
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local http = require("http")
local json = require("json")
local ai = require("ai")
local fs = require("fs")

local port = 39902
local base = "http://127.0.0.1:" .. port
local scratch = assert(os.getenv("VARN_TEST_DIR"), "VARN_TEST_DIR is not set")

local app = http.createApp()

-- openai embeddings and images
app:post("/embeddings", function(ctx)
    local body = ctx:body()
    ctx:json({ data = { { embedding = { 0.1, 0.2, 0.3 } } }, usage = { prompt_tokens = 1, total_tokens = 1, model = body.model } })
end)
app:post("/images/generations", function(ctx)
    ctx:json({ data = { { b64_json = "aGVsbG8=", revised_prompt = "a cat" } } })
end)

-- anthropic streaming with a text delta, a thinking delta, a tool block, then usage and stop
app:post("/v1/messages", function(ctx)
    local body = ctx:body()
    if not body.stream then
        ctx:json({ content = { { type = "text", text = "claude says hi" } }, stop_reason = "end_turn", usage = { input_tokens = 4, output_tokens = 3 } })
        return
    end

    local sse = ctx:sse()
    sse:send("message_start", json.encode({ type = "message_start", message = { usage = { input_tokens = 5 } } }))
    sse:send("content_block_delta", json.encode({ type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "hmm" } }))
    sse:send("content_block_delta", json.encode({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = "Hello" } }))
    sse:send("content_block_delta", json.encode({ type = "content_block_delta", index = 0, delta = { type = "text_delta", text = " sky" } }))
    sse:send("message_delta", json.encode({ type = "message_delta", delta = { stop_reason = "end_turn" }, usage = { output_tokens = 7 } }))
    sse:close()
end)

-- gemini generate, stream and native image over a single catch-all, dispatched by the request method in the path
app:post("/v1beta/models/*", function(ctx)
    local path = ctx.req.path
    local body = ctx:body()

    if path:find("streamGenerateContent", 1, true) then
        local sse = ctx:sse()
        sse:send(json.encode({ candidates = { { content = { parts = { { text = "Gem" } } } } } }))
        sse:send(json.encode({ candidates = { { content = { parts = { { text = "ini" } } }, finishReason = "STOP" } }, usageMetadata = { promptTokenCount = 2, candidatesTokenCount = 3, totalTokenCount = 5 } }))
        sse:close()
        return
    end

    -- an image request asks for an IMAGE modality, so answer with inline image data
    local wantsImage = body.generationConfig and body.generationConfig.responseModalities
    if wantsImage then
        ctx:json({ candidates = { { content = { parts = { { inlineData = { mimeType = "image/png", data = "aW1n" } } } } } } })
        return
    end

    ctx:json({ candidates = { { content = { parts = { { text = "gemini hi" } } }, finishReason = "STOP" } }, usageMetadata = { promptTokenCount = 2, candidatesTokenCount = 3, totalTokenCount = 5 } })
end)

-- elevenlabs audio endpoints
app:post("/v1/text-to-speech/*", function(ctx)
    ctx:header("Content-Type", "audio/mpeg"):send("TTS_AUDIO")
end)
app:post("/v1/speech-to-text", function(ctx)
    ctx:json({ text = "transcribed words" })
end)
app:get("/v2/voices", function(ctx)
    ctx:json({ voices = { { voice_id = "v1", name = "Voice One" }, { voice_id = "v2", name = "Voice Two" } } })
end)
app:post("/v1/sound-generation", function(ctx)
    ctx:header("Content-Type", "audio/mpeg"):send("SFX_AUDIO")
end)

-- a plain image url for the saveImage download branch
app:get("/image.png", function(ctx)
    ctx:header("Content-Type", "image/png"):send("PNGBYTES")
end)

app:listen({ host = "127.0.0.1", port = port })

async.run(function()
    -- openai embed and image
    local openai = ai.client({ provider = "openai", baseUrl = base, apiKey = "test", model = "mock" })
    local emb = openai:embed({ input = "hello" })
    assert(emb.embeddings[1][1] == 0.1 and #emb.embeddings[1] == 3, "openai embed vector mismatch")
    local img = openai:image({ prompt = "a cat" })
    assert(img.images[1].base64 == "aGVsbG8=" and img.images[1].revisedPrompt == "a cat", "openai image mismatch")

    -- anthropic streaming assembles text, surfaces reasoning, and reports usage
    local claude = ai.client({ provider = "anthropic", baseUrl = base, apiKey = "test", model = "mock" })
    local text, reasoning = {}, {}
    local streamed = claude:stream({ messages = { { role = "user", content = "hi" } } }, function(event)
        if event.type == "text" then
            text[#text + 1] = event.delta
        elseif event.type == "reasoning" then
            reasoning[#reasoning + 1] = event.delta
        end
    end)
    assert(table.concat(text) == "Hello sky", "anthropic stream text mismatch")
    assert(streamed.text == "Hello sky", "anthropic stream accumulated mismatch")
    assert(streamed.reasoning == "hmm", "anthropic stream reasoning mismatch")
    assert(streamed.finishReason == "end_turn", "anthropic stream finish mismatch")
    assert(streamed.usage.outputTokens == 7, "anthropic stream usage mismatch")

    -- gemini generate, stream and image
    local gemini = ai.client({ provider = "gemini", baseUrl = base, apiKey = "test", model = "mock" })
    local gen = gemini:generate({ messages = { { role = "user", content = "hi" } } })
    assert(gen.text == "gemini hi" and gen.finishReason == "STOP", "gemini generate mismatch")
    assert(gen.usage.totalTokens == 5, "gemini generate usage mismatch")

    local gparts = {}
    local gstream = gemini:stream({ messages = { { role = "user", content = "hi" } } }, function(event)
        if event.type == "text" then
            gparts[#gparts + 1] = event.delta
        end
    end)
    assert(table.concat(gparts) == "Gemini", "gemini stream text mismatch")
    assert(gstream.finishReason == "STOP" and gstream.usage.totalTokens == 5, "gemini stream finish/usage mismatch")

    local gimg = gemini:image({ prompt = "a dog" })
    assert(gimg.images[1].base64 == "aW1n" and gimg.images[1].mediaType == "image/png", "gemini image mismatch")

    -- elevenlabs audio methods
    local audio = ai.audio({ provider = "elevenlabs", baseUrl = base, apiKey = "test" })
    local tts = audio:tts({ text = "hi" })
    assert(tts.audio == "TTS_AUDIO", "elevenlabs tts mismatch")
    local stt = audio:stt({ audio = "rawbytes" })
    assert(stt.text == "transcribed words", "elevenlabs stt mismatch")
    local voices = audio:voices()
    assert(#voices == 2 and voices[1].voice_id == "v1", "elevenlabs voices mismatch")
    local sfx = audio:soundEffect({ text = "rain" })
    assert(sfx.audio == "SFX_AUDIO", "elevenlabs sound effect mismatch")

    -- saveImage downloads a url and writes the bytes, saveAudio writes raw bytes
    local imgPath = scratch .. "/downloaded.png"
    ai.saveImage({ url = base .. "/image.png" }, imgPath)
    assert(fs.readFile(imgPath):await() == "PNGBYTES", "saveImage url branch mismatch")

    local audioPath = scratch .. "/clip.mp3"
    ai.saveAudio("CLIPBYTES", audioPath)
    assert(fs.readFile(audioPath):await() == "CLIPBYTES", "saveAudio mismatch")

    print("ai adapters ok")
end)
