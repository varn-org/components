-- generic async connection pool where acquire() hands back a free connection, opens a new one up to the cap, or yields on the event loop until one is released, a connection whose operation raised is dropped rather than returned so a poisoned stream never leaks back into the pool, running inside an async coroutine (async.spawn/async.run) like the connections it manages
local async = require("async")

local pool = {}

local Pool = {}
Pool.__index = Pool

-- new({ connect = fn, close = fn?, size = n? }) -> a pool that lazily opens up to `size` connections
function pool.new(options)
    if type(options) ~= "table" or type(options.connect) ~= "function" then
        error("[Pool] new requires a 'connect' function.")
    end

    return setmetatable({
        connect = options.connect,
        closeConn = options.close or function(conn) conn:close() end,
        cap = options.size or 16,
        free = {},
        open = 0,
        waiters = {},
        closed = false,
    }, Pool)
end

function Pool:acquire()
    while true do
        if self.closed then
            error("[Pool] the pool is closed.")
        end

        local conn = table.remove(self.free)
        if conn then
            return conn
        end

        if self.open < self.cap then
            self.open = self.open + 1
            local ok, result = pcall(self.connect)
            if not ok then
                self.open = self.open - 1

                -- the failed attempt freed the slot, so wake a waiter to retry it instead of stranding the others
                local wake = table.remove(self.waiters, 1)
                if wake then
                    wake()
                end

                error(result)
            end
            return result
        end

        -- every connection is checked out so block on a deferred that a release or drop wakes, then loop to re-check since the freed slot may have been taken by another acquirer in between
        local gate, wake = async.deferred()
        self.waiters[#self.waiters + 1] = wake
        gate:await()
    end
end

function Pool:release(conn)
    -- a connection returned after the pool closed is closed rather than pooled back into a pool that no longer hands them out
    if self.closed then
        self.open = self.open - 1
        pcall(self.closeConn, conn)
        return
    end

    self.free[#self.free + 1] = conn

    local wake = table.remove(self.waiters, 1)
    if wake then
        wake()
    end
end

function Pool:drop(conn)
    self.open = self.open - 1
    pcall(self.closeConn, conn)

    -- dropping frees a slot under the cap so let a waiter through to open a fresh connection
    local wake = table.remove(self.waiters, 1)
    if wake then
        wake()
    end
end

-- with(fn) runs fn(conn) on a pooled connection, releasing it on success and dropping it on failure
function Pool:with(fn)
    local conn = self:acquire()

    local ok, result = pcall(fn, conn)
    if ok then
        self:release(conn)
        return result
    end

    self:drop(conn)
    error(result)
end

function Pool:closeAll()
    self.closed = true

    for _, conn in ipairs(self.free) do
        pcall(self.closeConn, conn)
    end

    -- drop only the free connections from the open count so it keeps reflecting the ones still checked out
    self.open = self.open - #self.free
    self.free = {}

    -- wake every blocked acquirer so it stops waiting on a pool that will never hand out a connection
    for _, wake in ipairs(self.waiters) do
        wake()
    end
    self.waiters = {}
end

return pool
