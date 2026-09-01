-- deterministic adapter test against a local mock server, exercising the openai and anthropic request building and response and stream parsing with no network or api keys
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local http = require("http")
local json = require("json")
local ai = require("ai")

local port = 39901
local base = "http://127.0.0.1:" .. port

local app = http.createApp()

app:post("/chat/completions", function(ctx)
    local body = ctx:body()
    if body.stream then
        local sse = ctx:sse()
        sse:send(json.encode({ choices = { { delta = { role = "assistant" } } } }))
        sse:send(json.encode({ choices = { { delta = { content = "Hello" } } } }))
        sse:send(json.encode({ choices = { { delta = { content = " world" } } } }))
        sse:send(json.encode({ choices = { { delta = {}, finish_reason = "stop" } }, usage = { prompt_tokens = 3, completion_tokens = 2, total_tokens = 5 } }))
        sse:send("[DONE]")
        sse:close()
    elseif body.tools then
        ctx:json({ choices = { { message = { tool_calls = { { id = "call_1", type = "function", ["function"] = { name = "get_weather", arguments = '{"city":"Paris"}' } } } }, finish_reason = "tool_calls" } } })
    else
        ctx:json({ choices = { { message = { content = "hi there" }, finish_reason = "stop" } }, usage = { prompt_tokens = 1, completion_tokens = 1, total_tokens = 2 } })
    end
end)

app:post("/v1/messages", function(ctx)
    ctx:json({ content = { { type = "text", text = "claude says hi" } }, stop_reason = "end_turn", usage = { input_tokens = 4, output_tokens = 3 } })
end)

app:listen({ host = "127.0.0.1", port = port })

async.run(function()
    local openai = ai.client({ provider = "openai", baseUrl = base, apiKey = "test", model = "mock" })

    local gen = openai:generate({ messages = { { role = "user", content = "hi" } } })
    assert(gen.text == "hi there", "generate text mismatch")
    assert(gen.finishReason == "stop", "generate finish mismatch")
    assert(gen.usage.totalTokens == 2, "generate usage mismatch")

    local parts = {}
    local streamed = openai:stream({ messages = { { role = "user", content = "hi" } } }, function(event)
        if event.type == "text" then
            parts[#parts + 1] = event.delta
        end
    end)
    assert(table.concat(parts) == "Hello world", "stream deltas mismatch")
    assert(streamed.text == "Hello world", "stream accumulated mismatch")
    assert(streamed.finishReason == "stop", "stream finish mismatch")
    assert(streamed.usage.totalTokens == 5, "stream usage mismatch")

    local tooled = openai:generate({
        messages = { { role = "user", content = "weather" } },
        tools = { { name = "get_weather", description = "", parameters = { type = "object" } } },
    })
    assert(tooled.toolCalls and tooled.toolCalls[1], "missing tool call")
    assert(tooled.toolCalls[1].name == "get_weather", "tool name mismatch")
    assert(tooled.toolCalls[1].arguments == '{"city":"Paris"}', "tool args mismatch")
    assert(tooled.finishReason == "tool_calls", "tool finish mismatch")

    local claude = ai.client({ provider = "anthropic", baseUrl = base, apiKey = "test", model = "mock" })
    local claudeGen = claude:generate({ messages = { { role = "user", content = "hi" } } })
    assert(claudeGen.text == "claude says hi", "anthropic text mismatch")
    assert(claudeGen.finishReason == "end_turn", "anthropic finish mismatch")
    assert(claudeGen.usage.totalTokens == 7, "anthropic usage mismatch")

    print("ai mock ok")
end)
