-- retry provides retry-with-backoff plus a tiny scheduler built on async.
-- retry.run re-invokes a function until it succeeds or runs out of attempts, sleeping between tries with exponential backoff.
-- retry.after and retry.every schedule one-shot and repeating work on background coroutines, each returning a cancellable handle.
-- everything yields on the event loop so it must run inside an async coroutine.
local async = require("async")
local log = require("log")

local retry = {}

-- calls fn and normalizes the outcome where a function that raises is a failure.
-- a returned promise is awaited so a rejected promise is also a failure.
-- returns ok plus the result or error.
local function callOnce(fn)
    local ok, value = pcall(fn)
    if not ok then
        return false, value
    end

    -- a promise (a userdata or table carrying :await) is awaited so async failures count as retryable too
    local kind = type(value)
    if (kind == "userdata" or kind == "table") and type(value.await) == "function" then
        local awaited, err = value:await()
        if err ~= nil then
            return false, err
        end
        return true, awaited
    end

    return true, value
end

-- run calls fn and retries on failure up to opts.attempts times (default 3) with exponential backoff starting at opts.backoffMs (default 100) and multiplied by opts.factor (default 2) each retry.
-- fn may return a promise.
-- on success it returns the value and after the last failed attempt it re-raises the final error.
function retry.run(fn, opts)
    opts = opts or {}
    local attempts = opts.attempts or 3
    if type(attempts) ~= "number" or attempts < 1 then
        error("[Retry] attempts must be a number that is at least 1", 0)
    end
    local backoff = opts.backoffMs or 100
    local factor = opts.factor or 2

    local lastError
    for attempt = 1, attempts do
        local ok, value = callOnce(fn)
        if ok then
            return value
        end

        lastError = value
        -- sleep before every retry but not after the final failure
        if attempt < attempts then
            async.sleep(backoff):await()
            backoff = backoff * factor
        end
    end

    error("[Retry] All " .. attempts .. " attempt(s) failed: " .. tostring(lastError), 0)
end

-- a handle for scheduled work whose :cancel() stops a pending or repeating task and :isCancelled() reports its state
local Handle = {}
Handle.__index = Handle

function Handle:cancel()
    self.cancelled = true
end

function Handle:isCancelled()
    return self.cancelled
end

local function newHandle()
    return setmetatable({ cancelled = false }, Handle)
end

-- after runs fn once after ms milliseconds on a background coroutine.
-- it returns a handle whose :cancel() prevents fn from firing if called before the delay elapses.
function retry.after(ms, fn)
    local handle = newHandle()
    async.spawn(function()
        async.sleep(ms):await()
        if not handle.cancelled then
            local ok, err = pcall(fn)
            if not ok then
                log.error("[Retry] a scheduled task raised: " .. tostring(err))
            end
        end
    end)
    return handle
end

-- every runs fn repeatedly on a background coroutine, waiting ms milliseconds before each run.
-- it returns a handle whose :cancel() stops the loop.
-- the cancel is observed before fn is called and again before the next sleep, so an in-flight run finishes but no further run starts.
function retry.every(ms, fn)
    local handle = newHandle()
    async.spawn(function()
        while not handle.cancelled do
            async.sleep(ms):await()
            if handle.cancelled then
                break
            end
            local ok, err = pcall(fn)
            if not ok then
                log.error("[Retry] a repeating task raised, the schedule continues: " .. tostring(err))
            end
        end
    end)
    return handle
end

return retry
