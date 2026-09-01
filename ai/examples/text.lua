-- one-shot completion, with the model named as "provider/model" so the same call reaches any provider
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = {
            { role = "system", content = "You answer in one short sentence." },
            { role = "user", content = "Why is the sky blue?" },
        },
        max_tokens = 200,
    })

    print(response.choices[1].message.content)
    print(string.format("tokens: %d in, %d out", response.usage.prompt_tokens, response.usage.completion_tokens))
end)
