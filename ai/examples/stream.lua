-- streaming, where a handler receives openai-shaped chunks and the call still returns the assembled response
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = { { role = "user", content = "Count from one to ten in words." } },
        max_tokens = 200,
    }, function(chunk)
        local delta = chunk.choices[1].delta.content
        if delta then
            io.write(delta)
            io.flush()
        end
    end)

    print()
    print("finish reason: " .. tostring(response.choices[1].finish_reason))
end)
