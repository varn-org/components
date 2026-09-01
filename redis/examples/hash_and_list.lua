-- works with redis hashes and lists to show how array and map replies come back to lua, pointed at a server with VARN_REDIS_HOST / VARN_REDIS_PORT (and VARN_REDIS_USER / VARN_REDIS_PASS)
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local redis = require("redis")

async.run(function()
    local client = redis.connect({
        host = os.getenv("VARN_REDIS_HOST") or "127.0.0.1",
        port = tonumber(os.getenv("VARN_REDIS_PORT") or "6379"),
        username = os.getenv("VARN_REDIS_USER"),
        password = os.getenv("VARN_REDIS_PASS"),
    })

    -- a hash stores related fields under one key
    client:del("user:1")
    client:hset("user:1", "name", "alice", "role", "admin")
    print("hget name:", client:hget("user:1", "name"))

    -- hgetall returns a flat array of field, value, field, value
    local flat = client:hgetall("user:1")
    local fields = {}
    for i = 1, #flat, 2 do
        fields[flat[i]] = flat[i + 1]
    end
    print("hash:", fields.name, fields.role)

    -- a list used as a simple queue
    client:del("queue")
    client:rpush("queue", "first", "second", "third")
    print("len:", client:llen("queue"))
    print("pop:", client:lpop("queue"))

    local rest = client:lrange("queue", 0, -1)
    print("remaining:", table.concat(rest, ", "))

    client:del("user:1", "queue")
    client:close()

    print("redis hash and list ok")
end)
