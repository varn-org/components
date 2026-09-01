# 🏊 pool

A generic async connection pool written in pure Lua. `acquire()` hands back a free connection, opens
a new one up to the cap, or yields on the event loop until one is released. A connection whose
operation raised is dropped rather than returned, so a poisoned resource never leaks back into the
pool.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local pool = require("pool")
```

Every borrow and release runs on the event loop, so the whole lifecycle must live inside an async
coroutine (`async.run` / `async.spawn`). It is native-only, since it manages connections built on
`socket`/`http`/`vdo`, which are unavailable in the browser.

## Creating a pool

`pool.new(options)` → a pool.

| Option | Default | Meaning |
|--------|---------|---------|
| `connect` | required | called with no arguments to open and return a new connection |
| `close` | `conn:close()` | called with a connection to close it |
| `size` | `16` | maximum number of open connections |

```lua
local async = require("async")

async.run(function()
    local p = pool.new({
        connect = function() return openConnection() end,
        close = function(conn) conn:close() end,
        size = 8,
    })

    local rows = p:with(function(conn)
        return conn:query("select 1")
    end)

    p:closeAll()
end)
```

## Methods

| Function | What it does |
|---|---|
| `p:acquire()` | Return a free connection, open one up to `size`, or block until a release; raises if the pool is closed. |
| `p:release(conn)` | Return a connection to the free list and wake a waiter; closes the connection instead if the pool is closed. |
| `p:drop(conn)` | Close a connection and free its slot so a waiter can open a fresh one; use it for a connection left in a bad state. |
| `p:with(fn)` | Acquire a connection, run `fn(conn)`, release it and return the result on success, or drop it and re-raise on failure. |
| `p:closeAll()` | Close the pool and its idle connections; connections still checked out are closed when they are later released. |

## Semantics

- Connections open lazily, one per checkout, up to `size`. When the pool is full, `acquire` blocks on
  a deferred until a `release` or `drop` frees a slot.
- `with` is the safe path: on success the connection goes back to the free list, and on failure it is
  dropped and the error re-raised, so a connection left mid-protocol is never reused.
- After `closeAll()` the pool is closed, so `acquire` raises, and a connection still checked out is
  closed rather than pooled when it is later released.

## Examples

### `basic.lua`

```lua
-- shows a bounded connection pool reusing connections, borrowing one with :with, blocking a third acquirer until a release, and closing everything at the end
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local pool = require("pool")

async.run(function()
    -- a mock resource whose open count proves the pool is reusing connections rather than opening new ones
    local opened = 0
    local closed = 0
    local p = pool.new({
        connect = function()
            opened = opened + 1
            return { id = opened }
        end,
        close = function()
            closed = closed + 1
        end,
        size = 2,
    })

    -- :with borrows a connection, runs the body, and returns the connection to the pool
    local first = p:with(function(conn)
        return conn.id
    end)
    print("with used connection", first)

    -- a second :with reuses the same freed connection, so only one was ever opened
    p:with(function(conn) return conn.id end)
    print("connections opened so far:", opened)

    -- two held connections saturate the pool, so a third acquire blocks until one is released
    local a = p:acquire()
    local b = p:acquire()
    local gotThird = false
    async.spawn(function()
        local c = p:acquire()
        gotThird = true
        p:release(c)
    end)
    async.sleep(10):await()
    print("third acquire blocked while full:", not gotThird)
    p:release(a)
    async.sleep(10):await()
    print("third acquire unblocked after release:", gotThird)
    p:release(b)

    -- closeAll shuts the pool down and closes the idle connections
    p:closeAll()
    print("connections closed:", closed)

    print("pool basic ok")
end)
```
