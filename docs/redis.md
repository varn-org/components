# 🧰 redis

A Redis client written in Lua on top of the native `socket` module. It speaks RESP2 over a single
connection, so it runs inside an async coroutine (`async.spawn` / `async.run`) like any other socket
work.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local redis = require("redis")
```

## Connecting

`redis.connect(options)` → a client. All options are optional:

| Option | Default | Meaning |
|--------|---------|---------|
| `host` | `"127.0.0.1"` | server host |
| `port` | `6379` | server port |
| `hosts` | — | list of `{ host, port }` endpoints tried in order for failover |
| `username` | — | ACL user, sent as `AUTH user password` |
| `password` | — | password, sent as `AUTH password` when no username is set |
| `db` | — | database index, sent as `SELECT db` |
| `tls` | `false` | negotiate TLS before the handshake |
| `insecure` | `false` | with `tls`, skip certificate verification |
| `pipeline` | `false` | use a multiplexed connection that shares one socket across concurrent commands and auto-pipelines them |

```lua
local async = require("async")

async.run(function()
    local client = redis.connect({ host = "127.0.0.1", port = 6379, password = "secret" })
    -- ... use the client ...
    client:close()
end)
```

Authentication and database selection happen on connect, so a bad credential fails immediately.

### Failover

Pass `hosts` instead of a single `host`/`port` to list several endpoints. Each is tried in order —
connect, authenticate, select database — and the first one that comes fully online is used. If none
respond, the connect raises with every endpoint's error. The same `username`, `password`, and `db`
apply to whichever endpoint wins.

```lua
local client = redis.connect({
    hosts = {
        { host = "10.0.0.1", port = 6379 },
        { host = "10.0.0.2", port = 6379 },
    },
    password = "secret",
})
```

## Commands

Any method name is sent as the matching Redis command (command names are case-insensitive), so the
full command set is available without per-command wrappers:

```lua
client:set("greeting", "hello")
local value = client:get("greeting")   -- "hello"
client:incrby("hits", 5)
local values = client:mget("a", "b")   -- array, nil for a missing key
```

`client:command(name, ...)` does the same thing explicitly, which is handy for multi-word commands:

```lua
client:command("CONFIG", "GET", "maxmemory")
```

Replies map to Lua: a simple string or bulk string becomes a string, an integer becomes a number, a
null becomes `nil`, and an array becomes a table (with `nil` for any null element). A server error
reply is raised as a Lua error, so wrap a call in `pcall` to inspect it.

## Pipelining

`client:pipeline(builder)` queues several commands, sends them in one write, and returns their
replies in order. Every reply is read before any error is raised, so the stream never desyncs:

```lua
local replies = client:pipeline(function(p)
    p:set("counter", "100")
    p:incrby("counter", 5)
    p:get("counter")
end)
-- replies = { "OK", 105, "105" }
```

## Lifecycle

- `client:close()` → closes the underlying socket.

## Examples

### `basic.lua`

```lua
-- basic strings and counters over a single connection.
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

    client:set("greeting", "hello from varn")
    print("get:", client:get("greeting"))

    client:del("hits")
    print("incr:", client:incr("hits"))
    print("incrby:", client:incrby("hits", 9))

    client:set("a", "1")
    client:set("b", "2")
    local values = client:mget("a", "missing", "b")
    print("mget:", values[1], values[2], values[3])

    client:del("greeting", "hits", "a", "b")
    client:close()

    print("redis basic ok")
end)
```

### `hash_and_list.lua`

```lua
-- works with redis hashes and lists, showing how array and map replies come back to lua.
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

    client:del("user:1")
    client:hset("user:1", "name", "alice", "role", "admin")
    print("hget name:", client:hget("user:1", "name"))

    local flat = client:hgetall("user:1")
    local fields = {}
    for i = 1, #flat, 2 do
        fields[flat[i]] = flat[i + 1]
    end
    print("hash:", fields.name, fields.role)

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
```
