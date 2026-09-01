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
