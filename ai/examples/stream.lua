-- streaming generation printing tokens as they arrive through the onEvent callback
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local result = client:stream({
        messages = { { role = "user", content = "write one short sentence about the ocean" } },
        maxTokens = 64,
    }, function(event)
        if event.type == "text" then
            io.write(event.delta)
            io.flush()
        end
    end)

    print()
    print("finish:", result.finishReason)
end)
