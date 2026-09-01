-- full tool-calling round trip where the model requests a tool, the program runs it, and the result is fed back for a final answer
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local weatherTool = {
    name = "get_weather",
    description = "get the current temperature for a city",
    parameters = {
        type = "object",
        properties = { city = { type = "string" } },
        required = { "city" },
    },
}

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local messages = { { role = "user", content = "what is the weather in Paris?" } }

    local first = client:generate({ messages = messages, tools = { weatherTool }, maxTokens = 256 })
    local call = first.toolCalls and first.toolCalls[1]
    assert(call, "the model did not call the tool")
    print("model called:", call.name, call.arguments)

    -- record the assistant turn that issued the call, then answer it
    messages[#messages + 1] = { role = "assistant", content = first.text, toolCalls = first.toolCalls }
    local args = json.decode(call.arguments)
    local reading = string.format("%d degrees celsius", 21)
    messages[#messages + 1] = { role = "tool", toolCallId = call.id, name = call.name, content = reading }
    print("tool result for", args.city, "->", reading)

    local final = client:generate({ messages = messages, tools = { weatherTool }, maxTokens = 256 })
    print("answer:", final.text)
end)
