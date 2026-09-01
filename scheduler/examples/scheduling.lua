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
