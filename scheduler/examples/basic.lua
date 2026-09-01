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
