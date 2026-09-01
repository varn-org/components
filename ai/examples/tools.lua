-- tool calling, where the model asks for a function, the program answers, and the conversation continues
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local tools = {
    {
        type = "function",
        ["function"] = {
            name = "get_weather",
            description = "Current weather for a city",
            parameters = {
                type = "object",
                properties = { city = { type = "string" } },
                required = { "city" },
            },
        },
    },
}

async.run(function()
    local model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini"
    local messages = { { role = "user", content = "What is the weather in Lisbon?" } }

    local first = ai.completion({ model = model, messages = messages, tools = tools, max_tokens = 300 })
    local call = first.choices[1].message.tool_calls[1]
    print("model asked for: " .. call["function"].name .. " " .. call["function"].arguments)

    -- the assistant turn and the tool result both go back so the model can use the answer
    messages[#messages + 1] = first.choices[1].message
    messages[#messages + 1] = {
        role = "tool",
        tool_call_id = call.id,
        content = json.encode({ city = json.decode(call["function"].arguments).city, celsius = 21, sky = "clear" }),
    }

    local second = ai.completion({ model = model, messages = messages, tools = tools, max_tokens = 300 })
    print(second.choices[1].message.content)
end)
