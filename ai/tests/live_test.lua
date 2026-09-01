-- live test against the real provider apis, gated per provider on its api key so a missing key skips that provider.
-- calls are kept tiny to stay cheap, and each one asserts the same openai-shaped contract regardless of the wire underneath.
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

local prompt = { { role = "user", content = "Reply with only the single word: ok" } }

local function has(key)
    local value = os.getenv(key)
    return value ~= nil and #value > 0
end

local function check(condition, message)
    if not condition then
        error(message, 2)
    end
end

-- every provider must answer the same shape, so one assertion serves them all
local function assertCompletion(label, response)
    check(response.choices and response.choices[1], label .. ": no choice returned")
    check(type(response.choices[1].message.content) == "string", label .. ": no message content")
    check(#response.choices[1].message.content > 0, label .. ": empty message content")
    check(response.choices[1].finish_reason ~= nil, label .. ": no finish reason")
    print(string.format("  %-28s %s", label, response.choices[1].message.content:gsub("%s+", " "):sub(1, 40)))
end

local providers = {
    { key = "OPENAI_API_KEY", model = "openai/gpt-4o-mini" },
    { key = "ANTHROPIC_API_KEY", model = "anthropic/claude-haiku-4-5", max_tokens = 32 },
    { key = "GEMINI_API_KEY", model = "gemini/gemini-2.5-flash" },
    { key = "XAI_API_KEY", model = "xai/grok-4-fast" },
    { key = "DEEPSEEK_API_KEY", model = "deepseek/deepseek-chat" },
    { key = "GROQ_API_KEY", model = "groq/llama-3.3-70b-versatile" },
    { key = "MISTRAL_API_KEY", model = "mistral/mistral-small-latest" },
    { key = "OPENROUTER_API_KEY", model = "openrouter/openai/gpt-4o-mini" },
    { key = "COHERE_API_KEY", model = "cohere/command-a-03-2025", max_tokens = 32 },
}

async.run(function()
    local ran = 0

    print("completion:")
    for _, provider in ipairs(providers) do
        if has(provider.key) then
            assertCompletion(provider.model, ai.completion({
                model = provider.model,
                messages = prompt,
                max_tokens = provider.max_tokens or 32,
            }))
            ran = ran + 1
        end
    end

    -- streaming must deliver deltas and still assemble the same response
    print("streaming:")
    for _, provider in ipairs(providers) do
        if has(provider.key) then
            local deltas = {}
            local response = ai.completion({
                model = provider.model,
                messages = prompt,
                max_tokens = provider.max_tokens or 32,
            }, function(chunk)
                local content = chunk.choices[1].delta.content
                if content then
                    deltas[#deltas + 1] = content
                end
            end)

            check(#deltas > 0, provider.model .. ": stream produced no deltas")
            check(response.choices[1].message.content == table.concat(deltas), provider.model .. ": assembled text differs from the deltas")
            print(string.format("  %-28s %d deltas", provider.model, #deltas))
            ran = ran + 1
        end
    end

    if has("OPENAI_API_KEY") then
        print("embeddings:")
        local embedded = ai.embedding({ model = "openai/text-embedding-3-small", input = "varn" })
        check(#embedded.data[1].embedding > 100, "openai: embedding is too short")
        print(string.format("  %-28s %d dimensions", "openai/text-embedding-3-small", #embedded.data[1].embedding))
        ran = ran + 1
    end

    if ran == 0 then
        print("no provider keys set, nothing ran")
        return
    end

    print(string.format("ai live ok (%d calls)", ran))
end)
