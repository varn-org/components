-- live integration test for the ai adapters against the real provider apis, gated per provider on its api key so a missing key skips that provider.
-- calls are kept tiny (a one-word reply, a short embedding, a voice listing) to stay cheap, and saveImage's base64 branch runs with no api.
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")
local fs = require("fs")

local scratch = assert(os.getenv("VARN_TEST_DIR"), "VARN_TEST_DIR is not set")

local function has(key)
    local value = os.getenv(key)
    return value ~= nil and #value > 0
end

local prompt = { { role = "user", content = "Reply with only the single word: ok" } }

local function collectStream(client)
    local parts = {}
    local result = client:stream({ messages = prompt, maxTokens = 512 }, function(event)
        if event.type == "text" then
            parts[#parts + 1] = event.delta
        end
    end)
    return result
end

async.run(function()
    local tested = {}

    if has("OPENAI_API_KEY") then
        local client = ai.client({ provider = "openai", model = "gpt-4o-mini" })
        local gen = client:generate({ messages = prompt, maxTokens = 512 })
        assert(type(gen.text) == "string" and #gen.text > 0, "openai generate should return text")
        assert(gen.usage and gen.usage.totalTokens and gen.usage.totalTokens > 0, "openai generate should report usage")

        local streamed = collectStream(client)
        assert(type(streamed.text) == "string" and #streamed.text > 0, "openai stream should accumulate text")

        local emb = client:embed({ model = "text-embedding-3-small", input = "hello" })
        assert(emb.embeddings and emb.embeddings[1] and #emb.embeddings[1] > 0, "openai embed should return a vector")
        tested[#tested + 1] = "openai"
    end

    if has("ANTHROPIC_API_KEY") then
        local client = ai.client({ provider = "anthropic", model = "claude-haiku-4-5-20251001" })
        local gen = client:generate({ messages = prompt, maxTokens = 512 })
        assert(type(gen.text) == "string" and #gen.text > 0, "anthropic generate should return text")

        local streamed = collectStream(client)
        assert(type(streamed.text) == "string" and #streamed.text > 0, "anthropic stream should accumulate text")
        tested[#tested + 1] = "anthropic"
    end

    if has("GEMINI_API_KEY") then
        local client = ai.client({ provider = "gemini", model = "gemini-2.5-flash" })
        local gen = client:generate({ messages = prompt, maxTokens = 512 })
        assert(type(gen.text) == "string" and #gen.text > 0, "gemini generate should return text")

        local streamed = collectStream(client)
        assert(type(streamed.text) == "string" and #streamed.text > 0, "gemini stream should accumulate text")
        tested[#tested + 1] = "gemini"
    end

    if has("ELEVENLABS_API_KEY") then
        local audio = ai.audio({ provider = "elevenlabs" })
        local voices = audio:voices()
        assert(type(voices) == "table", "elevenlabs voices should return a list")
        tested[#tested + 1] = "elevenlabs"
    end

    -- saveImage decodes a base64 image to disk without touching any api
    local onePixelPng =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    local imagePath = scratch .. "/pixel.png"
    ai.saveImage({ base64 = onePixelPng }, imagePath)
    assert(fs.exists(imagePath), "saveImage should write the decoded image to disk")

    print("ai live ok (" .. (next(tested) and table.concat(tested, ", ") or "no keys, saveImage only") .. ")")
end)
