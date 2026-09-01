-- structured output asking for json conforming to a schema and decoding the response with the openai-style response_format
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local response = client:generate({
        messages = { { role = "user", content = "give two facts about the moon" } },
        responseFormat = {
            type = "json_schema",
            json_schema = {
                name = "facts",
                strict = true,
                schema = {
                    type = "object",
                    properties = { facts = { type = "array", items = { type = "string" } } },
                    required = { "facts" },
                    additionalProperties = false,
                },
            },
        },
        maxTokens = 256,
    })

    local decoded = json.decode(response.text)
    for index, fact in ipairs(decoded.facts) do
        print(index, fact)
    end
end)
