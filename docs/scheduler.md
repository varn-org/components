# ⏰ scheduler

A durable background task scheduler written in Lua on top of the [vdo](vdo.md) store. Run work
immediately, at a future time, or on an interval, with full status and history, surviving restarts
and returning interrupted tasks to the queue.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local scheduler = require("scheduler")
```

The tick loop and the handlers run on the event loop, so the whole lifecycle must live inside an
async coroutine (`async.run` / `async.spawn`). It is native-only, since it depends on `vdo`
(ffi-backed SQLite/MySQL/PostgreSQL).

```lua
local async = require("async")

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

## Durability contract

- Tasks reference a **named handler plus a json payload**, never a closure, so the queue is fully
  reconstructable from the store after a restart.
- A running task carries a **lease** that its owning instance renews every tick. `start()` and the
  tick loop return a task to `queued` only when its lease has lapsed, so a task interrupted by a
  crash or a restart runs again after at most `leaseSeconds`.
- The lease makes the store **safe to share across several scheduler instances**: a peer that is
  still alive keeps renewing its lease, so its in-flight tasks are never stolen, and only a dead
  peer's tasks are reclaimed.
- Delivery is **at-least-once**, so handlers should be idempotent.

## Creating a scheduler

`scheduler.new(config)` → a scheduler, with the schema ensured on the store.

| Option | Default | Meaning |
|--------|---------|---------|
| `dsn` | `"sqlite:scheduler.db"` | the vdo DSN backing the queue |
| `concurrency` | `4` | tasks dispatched in parallel per tick |
| `pollMs` | `1000` | tick interval |
| `backoffSeconds` | `1` | first retry delay after a failure |
| `maxBackoffSeconds` | `300` | ceiling for the exponential backoff |
| `leaseSeconds` | `30` | how long a running task is held before an idle lease is reclaimable |

## Triggers

| Function | What it does |
|---|---|
| `jobs:handler(name, fn)` | Register the handler `fn(payload, task)` invoked for tasks of that name. |
| `jobs:enqueue(name, payload, opts)` | Run as soon as the next tick reaches it. |
| `jobs:schedule(name, payload, runAt, opts)` | Run once at the unix time `runAt`. |
| `jobs:every(name, payload, intervalSeconds, opts)` | Run now and re-arm every `intervalSeconds` after each success. |

Each returns the task id. `opts` takes `id` (a stable id, which makes the trigger idempotent),
`priority` (higher runs first), and `maxAttempts` (retries on failure, default 1).

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

A task moves through `scheduled` (waiting for its time), `queued` (ready to run), `running`, and then
`success`, `failed` (retries exhausted), or `cancelled`. A failing task with attempts left re-arms as
`scheduled` after an exponential backoff, and an interval task re-arms as `scheduled` after each
success.

## Examples

### `basic.lua`

```lua
-- register a handler, enqueue a task, and read back its status, result, and run history
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local scheduler = require("scheduler")

async.run(function()
    local jobs = scheduler.new({ dsn = "sqlite::memory:", pollMs = 50 })

    jobs:handler("greet", function(payload)
        print("running greet for", payload.name)
        return { message = "hello " .. payload.name }
    end)

    jobs:start()

    local id = jobs:enqueue("greet", { name = "world" })
    async.sleep(300):await()

    local task = jobs:get(id)
    print("state:", task.state)
    print("result:", task.result and task.result.message)
    for _, run in ipairs(jobs:history(id)) do
        print("run", run.attempt, run.state)
    end

    jobs:close()
end)
```

### `scheduling.lua`

```lua
-- schedule a task for a future time and a recurring task on an interval, then list and cancel
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local scheduler = require("scheduler")

async.run(function()
    local jobs = scheduler.new({ dsn = "sqlite::memory:", pollMs = 50 })

    jobs:handler("tick", function(payload)
        print("tick", payload.label, "at", os.date("!%H:%M:%S"))
        return true
    end)

    jobs:start()

    local laterId = jobs:schedule("tick", { label = "delayed" }, os.time() + 2)
    local everyId = jobs:every("tick", { label = "recurring" }, 1)
    print("scheduled", laterId)
    print("recurring", everyId)

    async.sleep(2500):await()

    print("tasks:")
    for _, task in ipairs(jobs:list()) do
        print(" ", task.name, task.state)
    end

    jobs:cancel(everyId)
    jobs:close()
end)
```

### `recovery.lua`

```lua
-- shows crash recovery where a task left running by a dead process returns to the queue and is processed on the next start
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local vdo = require("vdo")
local scheduler = require("scheduler")

async.run(function()
    local path = os.getenv("SCHEDULER_DB") or "/tmp/varn_scheduler_recovery.db"
    os.remove(path)

    local jobs = scheduler.new({ dsn = "sqlite:" .. path, pollMs = 50 })
    jobs:handler("work", function()
        print("processing the reclaimed task")
        return { done = true }
    end)

    -- simulate a previous process that died with a task still marked running
    local store = vdo.connect("sqlite:" .. path)
    local now = os.time()
    local seed = store:prepare(
        "INSERT INTO scheduler_tasks (id, name, payload, state, priority, run_at, attempts, max_attempts, created_at, updated_at) VALUES ('job-1', 'work', NULL, 'running', 0, :now, 0, 1, :now, :now)"
    )
    seed:execute({ now = now })
    seed:close()
    store:close()

    print("before start:", jobs:get("job-1").state)

    jobs:start()
    async.sleep(300):await()

    print("after start:", jobs:get("job-1").state)

    jobs:close()
    os.remove(path)
end)
```
