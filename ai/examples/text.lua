-- one-shot text generation, provider chosen by AI_PROVIDER (default openai) with the key read from the matching environment variable
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local response = client:generate({
        system = "you answer in a single short sentence",
        messages = { { role = "user", content = "name the three primary colors" } },
        temperature = 0.2,
        maxTokens = 64,
    })

    print(response.text)
    print("finish:", response.finishReason)
    if response.usage then
        print("tokens:", response.usage.totalTokens)
    end
end)
