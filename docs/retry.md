# 🔁 Retry
Retry-with-backoff plus a tiny scheduler, built on the native `async` module. `retry.run` re-invokes
a function until it succeeds; `retry.after` and `retry.every` schedule one-shot and repeating work.
Everything yields on the event loop, so it runs inside an async coroutine (`async.spawn` /
`async.run`).

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local async = require("async")
local retry = require("retry")
```

## Retrying

`retry.run(fn, opts?)` calls `fn`, retrying on failure with exponential backoff. A failure is `fn`
raising, or `fn` returning a promise that rejects — a returned promise is awaited, so async work is
retried too. On success the value is returned; after the last failed attempt the final error is
re-raised.

| Option | Default | Meaning |
|--------|---------|---------|
| `attempts` | `3` | total tries |
| `backoffMs` | `100` | delay before the first retry |
| `factor` | `2` | the backoff is multiplied by this before each subsequent retry |

The delay grows `backoffMs`, `backoffMs * factor`, `backoffMs * factor²`, … and there is no sleep
after the final failure.

```lua
async.run(function()
    local result = retry.run(function()
        return callFlakyService()   -- may raise or return a promise
    end, { attempts = 5, backoffMs = 100, factor = 2 })
end)
```

## Scheduling

Both return a handle with `:cancel()` and `:isCancelled()`.

- `retry.after(ms, fn)` → runs `fn` once after `ms` milliseconds. Cancelling before the delay
  elapses prevents `fn` from firing.
- `retry.every(ms, fn)` → runs `fn` repeatedly, waiting `ms` milliseconds before each run.
  Cancelling stops the loop; an in-flight run finishes but no further run starts.

```lua
async.run(function()
    retry.after(1000, function()
        print("ran once after a second")
    end)

    local ticks = 0
    local handle
    handle = retry.every(500, function()
        ticks = ticks + 1
        if ticks == 3 then
            handle:cancel()
        end
    end)

    async.sleep(2000):await()
end)
```

> Because timers run on background coroutines, keep the program alive (for example with
> `async.sleep`) long enough for them to fire — `async.run` exits as soon as its body returns.

## Example

### `basic.lua`

Shows a flaky operation recovering after two failures, a permanent failure exhausting its attempts,
a one-shot timer, and a repeating interval cancelled after three ticks.

```lua
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
```
