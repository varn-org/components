-- basic redis strings and counters over a single connection, pointed at a server with VARN_REDIS_HOST / VARN_REDIS_PORT (and VARN_REDIS_USER / VARN_REDIS_PASS)
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

    print("ping:", client:command("PING"))

    -- dynamic dispatch turns any method name into the matching redis command
    client:set("greeting", "hello from varn")
    print("get:", client:get("greeting"))

    client:del("hits")
    print("incr:", client:incr("hits"))
    print("incrby:", client:incrby("hits", 9))

    -- a multi-key read returns an array with nil for any missing key
    client:set("a", "1")
    client:set("b", "2")
    local values = client:mget("a", "missing", "b")
    print("mget:", values[1], values[2], values[3])

    client:del("greeting", "hits", "a", "b")
    client:close()

    print("redis basic ok")
end)
