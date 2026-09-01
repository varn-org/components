# ⏱ scheduler

Durable background task scheduler over the [vdo](../vdo) store. Run work immediately, at a future time, or on an interval, with full status and history, surviving restarts and returning interrupted tasks to the queue.

```lua
local async = require("async")
local scheduler = require("scheduler")

async.run(function()
    local jobs = scheduler.new({ dsn = "sqlite:jobs.db" })
    jobs:handler("send_email", function(payload)
        -- do the work, return any json-serializable result
        return { sent = payload.to }
    end)
    jobs:start()
    jobs:enqueue("send_email", { to = "user@example.com" })
end)
```

The tick loop and handlers run on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`). Native-only — it depends on `vdo` (ffi-backed sqlite/mysql/postgres).

## Durability contract

- Tasks reference a **named handler plus a json payload**, never a closure, so the queue is fully reconstructable from the store after a restart.
- A running task carries a **lease** that its owning instance renews every tick. `start()` and the tick loop return a task to `queued` only when its lease has lapsed, so a task interrupted by a crash or restart runs again after at most `leaseSeconds`.
- The lease makes the store **safe to share across multiple scheduler instances**: a peer that is still alive keeps renewing its lease, so its in-flight tasks are never stolen, and only a dead peer's tasks are reclaimed.
- Delivery is **at-least-once**, so handlers should be idempotent.

## Constructor

| Function | What it does |
|---|---|
| `scheduler.new(config)` | Open the store and ensure the schema; `config` takes `dsn` (default `sqlite:scheduler.db`), `concurrency` (default 4), `pollMs` (default 1000), `backoffSeconds` (default 1), `maxBackoffSeconds` (default 300), `leaseSeconds` (default 30, how long a running task is held before an idle lease is reclaimable). |

## Triggers

| Function | What it does |
|---|---|
| `jobs:handler(name, fn)` | Register the handler `fn(payload, task)` invoked for tasks of that name. |
| `jobs:enqueue(name, payload, opts)` | Run as soon as the next tick reaches it. |
| `jobs:schedule(name, payload, runAt, opts)` | Run once at the unix time `runAt`. |
| `jobs:every(name, payload, intervalSeconds, opts)` | Run now and re-arm every `intervalSeconds` after each success. |

`opts` takes `id` (a stable id for idempotency), `priority` (higher runs first), and `maxAttempts` (retries on failure, default 1).

## Lifecycle and management

| Function | What it does |
|---|---|
| `jobs:start()` | Reclaim orphaned tasks and start the tick loop; idempotent. |
| `jobs:stop()` | Stop the tick loop. |
| `jobs:close()` | Stop the loop and close the store. |
| `jobs:pause()` / `jobs:resume()` | Hold or release task dispatch while leaving the loop running. |
| `jobs:get(id)` | The task row, with `payload` and `result` decoded. |
| `jobs:list(filter)` | All tasks, or those matching `filter.state`. |
| `jobs:history(taskId)` | The recorded runs for a task. |
| `jobs:cancel(id)` | Cancel a task that has not started yet. |
| `jobs:remove(id)` | Delete a task. |

## States

A task moves through `scheduled` (waiting for its time), `queued` (ready to run), `running`, and then `success`, `failed` (retries exhausted), or `cancelled`. A failing task with remaining attempts re-arms as `scheduled` after an exponential backoff; an interval task re-arms as `scheduled` after each success.

## Reference, examples, and tests

- Full reference: [docs/components/scheduler.md](../docs/scheduler.md)
- Runnable examples: [examples/](examples/) — basic enqueue, future and interval scheduling, crash recovery.
- Test: [tests/scheduler_test.lua](tests/scheduler_test.lua) covers success, retry, cancel, scheduling, interval re-arm, and crash recovery. Run it directly with `./build/bin/varn components/scheduler/tests/scheduler_test.lua` on a platform where the `vdo` sqlite backend loads, since it is not part of the cross-platform `varn.py test` runner.
