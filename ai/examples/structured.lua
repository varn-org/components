-- structured output, where a json schema constrains the reply so it can be decoded directly
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local schema = {
    type = "object",
    properties = {
        city = { type = "string" },
        country = { type = "string" },
        population = { type = "integer" },
    },
    required = { "city", "country", "population" },
    additionalProperties = false,
}

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = { { role = "user", content = "Give me the facts for Lisbon." } },
        response_format = {
            type = "json_schema",
            json_schema = { name = "city_facts", schema = schema, strict = true },
        },
        max_tokens = 300,
    })

    local facts = json.decode(response.choices[1].message.content)
    print(string.format("%s, %s: %d people", facts.city, facts.country, facts.population))
end)
