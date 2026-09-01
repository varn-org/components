# 🔌 pool

Generic async connection pool. `acquire()` hands back a free connection, opens a new one up to the cap, or yields on the event loop until one is released, and a connection whose operation raised is dropped rather than returned so a poisoned resource never leaks back into the pool.

```lua
local async = require("async")
local pool = require("pool")

async.run(function()
    local p = pool.new({
        connect = function() return openConnection() end,
        close = function(conn) conn:close() end,
        size = 8,
    })

    -- :with borrows a connection, runs the body, and returns it to the pool
    local rows = p:with(function(conn)
        return conn:query("select 1")
    end)

    p:closeAll()
end)
```

Every borrow and release runs on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`). Native-only — it manages connections built on `socket`/`http`/`vdo`, which are unavailable in the browser.

## Semantics

- `acquire()` opens connections lazily, one per checkout, up to `size` (default 16), and blocks on a deferred when the pool is full until a `release` or `drop` frees a slot.
- A connection returned with `release` goes back into the free list; a connection whose operation raised is passed to `drop` instead, which closes it and frees its slot for a fresh one.
- After `closeAll()` the pool is closed, so `acquire` raises and a connection still checked out is closed rather than pooled when it is later released.

## Constructor

| Function | What it does |
|---|---|
| `pool.new(options)` | Build a pool; `options` requires `connect` (opens and returns a connection), and takes `close` (default `conn:close()`) and `size` (max open connections, default 16). |

## Pool methods

| Function | What it does |
|---|---|
| `p:acquire()` | Return a free connection, open one up to `size`, or block until a release; raises if the pool is closed. |
| `p:release(conn)` | Return a connection to the free list and wake a waiter; closes the connection instead if the pool is closed. |
| `p:drop(conn)` | Close a connection and free its slot so a waiter can open a fresh one; use it for a connection left in a bad state. |
| `p:with(fn)` | Acquire a connection, run `fn(conn)`, release it and return the result on success, or drop it and re-raise on failure. |
| `p:closeAll()` | Close the pool and its idle connections; connections still checked out are closed when they are later released. |

## Reference, examples, and tests

- Full reference: [docs/components/pool.md](../docs/pool.md)
- Runnable example: [examples/](examples/) — reuse, `:with`, a blocked third acquire, and `closeAll`.
- Test: [tests/](tests/) covers lazy open up to the cap, reuse of freed connections, blocking when full, `drop` opening a slot, `:with` releasing on success and dropping on failure, and `closeAll` accounting.
