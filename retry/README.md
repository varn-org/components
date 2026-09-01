# 🔁 retry

Retry-with-backoff plus a tiny timer scheduler built on [async](https://github.com/varn-org/varn/blob/main/modules/async). `retry.run` re-invokes a function until it succeeds or runs out of attempts, sleeping between tries with exponential backoff; `retry.after` and `retry.every` schedule one-shot and repeating work on background coroutines, each returning a cancellable handle.

```lua
local async = require("async")
local retry = require("retry")

async.run(function()
    local result = retry.run(function()
        -- do the work, return a value or a promise, or raise to trigger a retry
        return fetchSomething()
    end, { attempts = 5, backoffMs = 100, factor = 2 })

    local handle = retry.every(1000, function()
        print("tick")
    end)
    async.sleep(3500):await()
    handle:cancel()
end)
```

Everything yields on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`).

## Retrying

| Function | What it does |
|---|---|
| `retry.run(fn, opts)` | Call `fn` and retry on failure up to `opts.attempts` times (default 3), sleeping `opts.backoffMs` (default 100) before the first retry and multiplying that delay by `opts.factor` (default 2) each retry. A raised error is a failure, and a returned promise is awaited so a rejected promise is a failure too. On success it returns the value; after the last failed attempt it re-raises the final error. |

The backoff sleep happens before every retry but not after the final failure.

## Timers

| Function | What it does |
|---|---|
| `retry.after(ms, fn)` | Run `fn` once after `ms` milliseconds on a background coroutine. Returns a handle. |
| `retry.every(ms, fn)` | Run `fn` repeatedly on a background coroutine, waiting `ms` milliseconds before each run. Returns a handle. |

An `every` loop checks its handle before each run and before each sleep, so cancelling lets an in-flight run finish while stopping any further run from starting; an `after` cancelled before its delay elapses never fires.

## Handle

| Function | What it does |
|---|---|
| `handle:cancel()` | Stop a pending one-shot or a repeating loop. |
| `handle:isCancelled()` | Whether the handle has been cancelled. |

## Reference, examples, and tests

- Full reference: [docs/components/retry.md](../docs/retry.md)
- Runnable example: [examples/](examples/) — backoff recovering from transient failures, an exhausted permanent failure, a one-shot timer, and a repeating interval cancelled after a few ticks.
- Test: [tests/](tests/) covers backoff succeeding after failures, exhausting attempts, first-try success, awaiting a returned promise, a cancellable one-shot timer, and a stoppable repeating interval. Run it directly with `./build/bin/varn components/retry/tests/integration.lua`.
