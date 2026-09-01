# 🧠 redis

RESP2 client for Redis and compatible servers, built on the native `socket` module. Every command name maps dynamically to a Redis command, so any method call becomes the matching request over a single connection, with optional multi-endpoint failover and an opt-in multiplexed client that auto-pipelines concurrent commands.

```lua
local async = require("async")
local redis = require("redis")

async.run(function()
    local client = redis.connect({ host = "127.0.0.1", port = 6379 })

    client:set("greeting", "hello from varn")
    print(client:get("greeting"))

    print(client:incr("hits"))

    client:close()
end)
```

Every socket operation yields on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`), and a client must be closed in the same scope that opened it. Native-only — it depends on the native `socket` module, unavailable in the browser.

## Connection

| Function | What it does |
|---|---|
| `redis.connect(options)` | Open one connection and bring it fully online (auth then database select), returning the client. |

`options` takes `host` and `port` (default `127.0.0.1:6379`), or `hosts` as a list of `{ host, port }` tables tried in order for failover until one connects and answers. It also takes `username`, `password`, `db` (the database index to `SELECT`), `tls = true` to connect over TLS (with `insecure = true` to skip certificate verification), and `pipeline` — when `true` the connection is multiplexed and concurrent commands share it.

## Client API

| Function | What it does |
|---|---|
| `client:command(name, ...)` | Send one command by name and return its reply; raises only when the top-level reply is an error. |
| `client:<name>(...)` | Dynamic dispatch — any method name becomes the Redis command of that name, so `client:set(k, v)` and `client:get(k)` issue `SET` and `GET`. |
| `client:pipeline(builder)` | Queue commands inside `builder(p)` via the same dynamic dispatch, flush them in one write, and return the ordered replies from a single round trip. |
| `client:close()` | Close the connection. |

Replies map directly to Lua: simple and bulk strings as strings, integers as numbers, a nil bulk or nil array as `nil`, and arrays as sequence tables. A `MULTI` / `EXEC` transaction is issued through ordinary commands, where each queued command answers `"QUEUED"` and `EXEC` returns every result in order.

## Multiplexed client

With `pipeline = true` the client shares one connection across many concurrent commands (the ioredis model). You do **not** call `:pipeline(builder)` on it — instead, commands issued from concurrent coroutines are batched into a single send automatically, and each resolves with its own reply in request order. The command API is otherwise identical, so `mux:set(k, v)` and `mux:get(k)` work exactly as on the single-connection client.

## Reference, examples, and tests

- Full reference: [docs/components/redis.md](../docs/redis.md)
- Runnable examples: [examples/](examples/) — string values and counters, and hashes and lists.
- Test: [tests/](tests/) covers endpoint failover, cached values with expiry, counters, hashes, lists, sets, sorted-set leaderboards, `MULTI` / `EXEC`, pipelines, and the multiplexed client. It needs a live Redis server (`VARN_REDIS_HOST` / `VARN_REDIS_PORT`, and `VARN_REDIS_USER` / `VARN_REDIS_PASS` when the server requires auth), so it runs standalone rather than in the cross-platform `varn.py test` runner. Run it directly with `./build/bin/varn components/redis/tests/integration.lua`.
