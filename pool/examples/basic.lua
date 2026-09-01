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
