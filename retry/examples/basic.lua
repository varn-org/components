-- shows retry-with-backoff recovering from transient failures, a one-shot timer and a repeating interval cancelled after a few ticks
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local retry = require("retry")

async.run(function()
    -- a flaky operation that fails twice then succeeds on the third try
    local calls = 0
    local result = retry.run(function()
        calls = calls + 1
        if calls < 3 then
            error("transient failure " .. calls)
        end
        return "ok after " .. calls .. " tries"
    end, { attempts = 5, backoffMs = 20, factor = 2 })
    print("retry.run:", result)

    -- a permanent failure exhausts the attempts and raises
    local ok, err = pcall(retry.run, function()
        error("always down")
    end, { attempts = 3, backoffMs = 10 })
    print("retry exhausted:", ok, err)

    -- one-shot timer
    retry.after(30, function()
        print("after: fired once at ~30ms")
    end)

    -- repeating interval cancelled after three ticks
    local ticks = 0
    local handle
    handle = retry.every(25, function()
        ticks = ticks + 1
        print("every: tick " .. ticks)
        if ticks == 3 then
            handle:cancel()
        end
    end)

    -- let the timers run to completion
    async.sleep(200):await()
    print("interval cancelled:", handle:isCancelled())

    print("retry basic ok")
end)
