-- assert-based test for the connection pool covering lazy open up to the cap, reuse of freed connections, blocking beyond the cap until a release, drop opening a slot, :with releasing on success and dropping on failure, and closeAll accounting
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local pool = require("pool")

-- builds a pool over mock connections and reports how many were opened and closed
local function makePool(size)
    local state = { opened = 0, closed = 0 }
    local p = pool.new({
        connect = function()
            state.opened = state.opened + 1
            return { id = state.opened }
        end,
        close = function()
            state.closed = state.closed + 1
        end,
        size = size,
    })
    return p, state
end

async.run(function()
    -- new requires a connect function
    assert(not pcall(pool.new, {}), "new should reject a missing connect function")

    -- acquire opens lazily up to the cap and reuses a freed connection instead of opening a new one
    do
        local p, state = makePool(2)
        local a = p:acquire()
        local b = p:acquire()
        assert(state.opened == 2, "two acquires should open two connections")
        p:release(a)
        local c = p:acquire()
        assert(c == a, "a freed connection should be reused")
        assert(state.opened == 2, "reuse should not open a new connection")
        p:release(b)
        p:release(c)
    end

    -- a third acquire on a full pool blocks until a release wakes it
    do
        local p = makePool(2)
        local a = p:acquire()
        local b = p:acquire()
        local unblocked = false
        async.spawn(function()
            local c = p:acquire()
            unblocked = true
            p:release(c)
        end)
        async.sleep(5):await()
        assert(unblocked == false, "a third acquire should block while the pool is full")
        p:release(a)
        async.sleep(5):await()
        assert(unblocked == true, "releasing a connection should unblock the waiter")
        p:release(b)
    end

    -- :with releases the connection on success and drops it on failure so a poisoned connection is not reused
    do
        local p, state = makePool(1)
        local value = p:with(function(conn) return conn.id end)
        assert(value == 1, ":with should return the body result")

        local ok = pcall(function()
            p:with(function()
                error("operation failed")
            end)
        end)
        assert(not ok, ":with should propagate the body error")
        assert(state.closed == 1, "a failed :with should drop and close the connection")

        -- the dropped connection freed a slot, so the next acquire opens a fresh one
        local fresh = p:acquire()
        assert(fresh.id == 2, "a fresh connection should open after a drop")
        p:release(fresh)
    end

    -- closeAll keeps the open count of still-checked-out connections and refuses new acquires
    do
        local p, state = makePool(2)
        local held = p:acquire()
        assert(p.open == 1, "one connection should be open")
        p:closeAll()
        assert(p.open == 1, "closeAll should still count the checked-out connection")

        p:release(held)
        assert(p.open == 0, "releasing after close should close the connection and drop the count")
        assert(state.closed == 1, "the returned connection should be closed on a closed pool")
        assert(not pcall(function() return p:acquire() end), "acquire on a closed pool should error")
    end

    -- a connect failure while waiters are blocked must wake the next waiter instead of stranding it
    do
        local attempts = 0
        local p = pool.new({
            connect = function()
                attempts = attempts + 1
                if attempts == 1 then
                    return { id = 1 }
                end
                error("connect failed")
            end,
            size = 1,
        })

        local holder = p:acquire()
        local finished = 0
        local errored = 0
        for _ = 1, 2 do
            async.spawn(function()
                local ok = pcall(function() return p:acquire() end)
                finished = finished + 1
                if not ok then
                    errored = errored + 1
                end
            end)
        end

        async.sleep(5):await()
        assert(finished == 0, "both waiters should block while the only connection is held")

        p:drop(holder)

        local waited = 0
        while finished < 2 and waited < 2000 do
            async.sleep(5):await()
            waited = waited + 5
        end
        assert(finished == 2, "a connect failure must wake every blocked waiter rather than stranding one")
        assert(errored == 2, "both waiters should observe the connect failure")
    end

    -- a stress run where many concurrent workers share a small pool and every one completes without deadlock
    do
        local p, state = makePool(4)
        local completed = 0
        local workers = 50
        for i = 1, workers do
            async.spawn(function()
                p:with(function(conn)
                    async.sleep(i % 3):await()
                    return conn.id
                end)
                completed = completed + 1
            end)
        end

        local waited = 0
        while completed < workers and waited < 5000 do
            async.sleep(5):await()
            waited = waited + 5
        end
        assert(completed == workers, "every worker should finish sharing the pool without deadlock")
        assert(state.opened <= 4, "the pool should never open more than its cap")
        p:closeAll()
    end

    -- with no close option, the default closeConn calls conn:close() when a connection is dropped
    do
        local closed = false
        local dp = pool.new({
            connect = function()
                return { close = function() closed = true end }
            end,
            size = 1,
        })
        local c = dp:acquire()
        dp:drop(c)
        assert(closed, "the default closeConn should call conn:close()")
    end

    print("pool integration ok")
end)
