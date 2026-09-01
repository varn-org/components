-- scheduler behavior over an in-memory store plus a file-backed crash-recovery case, covering success with result and history, retry with backoff, cancel, future scheduling, interval re-arm, and reclaiming a task left running by a dead process
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local scheduler = require("scheduler")

async.run(function()
    local store = scheduler.new({ dsn = "sqlite::memory:", pollMs = 20, backoffSeconds = 60 })

    local ran = {}
    store:handler("ok_task", function(payload)
        ran[#ran + 1] = payload.x
        return { doubled = payload.x * 2 }
    end)
    store:handler("fail_task", function()
        error("boom")
    end)

    store:start()

    -- success carries the handler result and records one run in history
    local okId = store:enqueue("ok_task", { x = 21 })
    async.sleep(200):await()
    local okTask = store:get(okId)
    assert(okTask.state == "success", "expected success, got " .. tostring(okTask.state))
    assert(okTask.result.doubled == 42, "result not stored")
    assert(ran[1] == 21, "handler did not receive the payload")
    local runs = store:history(okId)
    assert(#runs == 1 and runs[1].state == "success", "history not recorded")

    -- a future task stays scheduled and can be cancelled before it runs
    local futureId = store:schedule("ok_task", { x = 1 }, os.time() + 3600)
    async.sleep(60):await()
    assert(store:get(futureId).state == "scheduled", "future task should stay scheduled")
    assert(store:cancel(futureId), "cancel should report success")
    assert(store:get(futureId).state == "cancelled", "task should be cancelled")

    -- a failing task re-arms with an incremented attempt and the recorded error
    local retryId = store:enqueue("fail_task", {}, { maxAttempts = 3 })
    async.sleep(200):await()
    local retryTask = store:get(retryId)
    assert(retryTask.state == "scheduled", "failed task should re-arm, got " .. tostring(retryTask.state))
    assert(retryTask.attempts == 1, "attempts should be 1, got " .. tostring(retryTask.attempts))
    assert(retryTask.last_error and retryTask.last_error:find("boom", 1, true), "error not recorded")

    -- an interval task re-arms to a future scheduled run after succeeding
    local intervalId = store:every("ok_task", { x = 2 }, 60)
    async.sleep(200):await()
    local intervalTask = store:get(intervalId)
    assert(intervalTask.state == "scheduled", "interval task should re-arm to scheduled")
    assert(intervalTask.run_at > os.time(), "interval task should be scheduled ahead")

    store:close()

    -- a task left running by a dead process returns to the queue on the next start
    local path = (os.getenv("VARN_TEST_DIR") or ".") .. "/varn_scheduler_recovery.db"
    os.remove(path)
    local seed = scheduler.new({ dsn = "sqlite:" .. path })
    seed:_exec(
        "INSERT INTO scheduler_tasks (id, name, payload, state, priority, run_at, attempts, max_attempts, lease_epoch, created_at, updated_at) VALUES ('orphan', 'ok_task', NULL, 'running', 0, :now, 0, 1, 'dead-epoch', :now, :now)",
        { now = os.time() }
    )
    seed:close()

    local restarted = scheduler.new({ dsn = "sqlite:" .. path, pollMs = 20 })
    -- pause so the reclaimed task is observed in the queue rather than immediately picked up by the loop
    restarted:pause()
    restarted:start()
    restarted:stop()
    assert(restarted:get("orphan").state == "queued", "orphaned running task should return to queued")
    restarted:close()
    os.remove(path)

    -- a task with a live lease from a peer is left alone while an expired lease is reclaimed
    local multiPath = (os.getenv("VARN_TEST_DIR") or ".") .. "/varn_scheduler_multi.db"
    os.remove(multiPath)
    local seedMulti = scheduler.new({ dsn = "sqlite:" .. multiPath })
    local now = os.time()
    seedMulti:_exec(
        "INSERT INTO scheduler_tasks (id, name, payload, state, priority, run_at, attempts, max_attempts, lease_epoch, lease_expires_at, created_at, updated_at) VALUES ('live', 'ok_task', NULL, 'running', 0, :now, 0, 1, 'peer', :future, :now, :now)",
        { now = now, future = now + 3600 }
    )
    seedMulti:_exec(
        "INSERT INTO scheduler_tasks (id, name, payload, state, priority, run_at, attempts, max_attempts, lease_epoch, lease_expires_at, created_at, updated_at) VALUES ('dead', 'ok_task', NULL, 'running', 0, :now, 0, 1, 'peer', :past, :now, :now)",
        { now = now, past = now - 1 }
    )
    seedMulti:close()

    local peer = scheduler.new({ dsn = "sqlite:" .. multiPath })
    peer:pause()
    peer:start()
    peer:stop()
    assert(peer:get("live").state == "running", "a task with a live peer lease must not be reclaimed")
    assert(peer:get("dead").state == "queued", "a task with an expired lease must be reclaimed")
    peer:close()
    os.remove(multiPath)

    print("scheduler ok")
end)
