-- assert-based test for retry covering backoff succeeding after failures, exhausting attempts, succeeding on the first try, awaiting a returned promise, a cancellable one-shot timer and a stoppable repeating interval.
-- it runs inside async.run since every timer yields on the event loop.
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local retry = require("retry")

async.run(function()
    -- retries until the function stops failing and returns its value
    local calls = 0
    local value = retry.run(function()
        calls = calls + 1
        if calls < 3 then
            error("fail " .. calls)
        end
        return "done"
    end, { attempts = 5, backoffMs = 5, factor = 2 })
    assert(value == "done", "retry returns the eventual success value")
    assert(calls == 3, "retry stops as soon as it succeeds")
    print("retry success ok (took " .. calls .. " tries)")

    -- a function that always fails exhausts its attempts and raises
    local attempts = 0
    local ok, err = pcall(retry.run, function()
        attempts = attempts + 1
        error("permanent")
    end, { attempts = 3, backoffMs = 5 })
    assert(not ok, "exhausted retry raises")
    assert(attempts == 3, "all attempts are used")
    assert(tostring(err):find("permanent"), "final error is surfaced")
    print("retry exhaustion ok")

    -- succeeding on the first try makes exactly one call
    local once = 0
    local first = retry.run(function()
        once = once + 1
        return 42
    end)
    assert(first == 42 and once == 1, "first-try success calls once")

    -- a returned promise is awaited where a value resolves and an error rejects and retries
    local promiseCalls = 0
    local resolved = retry.run(function()
        promiseCalls = promiseCalls + 1
        -- the returned promise is awaited and its resolved value is forwarded as the run result
        return async.promise(function()
            async.sleep(1):await()
            return "forwarded-value"
        end)
    end)
    assert(resolved == "forwarded-value" and promiseCalls == 1, "a resolving promise is awaited and its value forwarded")
    print("retry promise ok")

    -- a rejecting promise counts as a retryable failure and is retried until it resolves
    local rejCalls = 0
    local recovered = retry.run(function()
        rejCalls = rejCalls + 1
        if rejCalls < 2 then
            return async.promise(function()
                error("transient")
            end)
        end
        return "recovered"
    end, { attempts = 3, backoffMs = 5 })
    assert(recovered == "recovered" and rejCalls == 2, "a rejecting promise should be retried then succeed")

    -- after() fires once
    local fired = false
    retry.after(20, function()
        fired = true
    end)
    async.sleep(60):await()
    assert(fired, "after fires once")

    -- a cancelled after() never fires
    local cancelledFired = false
    local h = retry.after(40, function()
        cancelledFired = true
    end)
    h:cancel()
    async.sleep(80):await()
    assert(not cancelledFired, "cancelled after does not fire")
    assert(h:isCancelled(), "handle reports cancelled")
    print("after ok")

    -- every() ticks repeatedly and stops on cancel
    local ticks = 0
    local handle = retry.every(15, function()
        ticks = ticks + 1
    end)
    async.sleep(120):await()
    handle:cancel()
    local atCancel = ticks
    assert(atCancel >= 3, "interval ticked several times, got " .. atCancel)
    async.sleep(60):await()
    assert(ticks == atCancel, "no ticks after cancel")
    print("every ok (" .. atCancel .. " ticks before cancel)")

    -- every() keeps firing even when a run raises, so a transient error does not kill the schedule
    local survived = 0
    local throwHandle = retry.every(15, function()
        survived = survived + 1
        error("tick boom " .. survived)
    end)
    async.sleep(90):await()
    throwHandle:cancel()
    assert(survived >= 3, "every should keep firing after a throwing run, got " .. survived)
    print("every survives failures ok (" .. survived .. " runs)")

    -- run rejects an invalid attempt count instead of raising a nonsensical message without ever calling fn
    assert(not pcall(retry.run, function() return 1 end, { attempts = 0 }), "attempts of 0 should error")
    assert(not pcall(retry.run, function() return 1 end, { attempts = -3 }), "a negative attempts should error")

    print("retry integration ok")
end)
