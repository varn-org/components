-- real-application integration test for the redis client covering endpoint failover and the data structures an app leans on (cached values with expiry, counters, hashes, lists, sets, sorted-set leaderboards, MULTI/EXEC transactions, and pipelines), pointed at a server with VARN_REDIS_HOST / VARN_REDIS_PORT (and VARN_REDIS_USER / VARN_REDIS_PASS)
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local redis = require("redis")

local HOST = os.getenv("VARN_REDIS_HOST") or "127.0.0.1"
local PORT = tonumber(os.getenv("VARN_REDIS_PORT") or "6379")
local USER = os.getenv("VARN_REDIS_USER")
local PASS = os.getenv("VARN_REDIS_PASS")

local PREFIX = "varn:it:" .. tostring(os.time()) .. ":"

local function key(name)
    return PREFIX .. name
end

async.run(function()
    -- a dead endpoint is listed first so a working client proves failover moved on to the live one behind it
    local client = redis.connect({
        hosts = {
            { host = "127.0.0.1", port = 1 },
            { host = HOST, port = PORT },
        },
        username = USER,
        password = PASS,
    })
    assert(client:command("PING") == "PONG", "failover reached a live endpoint")
    print("failover ok: connected past a dead endpoint")

    -- cache entry with a time to live
    local cacheKey = key("cache")
    client:set(cacheKey, "cached-value", "EX", 100)
    assert(client:get(cacheKey) == "cached-value", "cache get")
    local ttl = client:ttl(cacheKey)
    assert(ttl > 0 and ttl <= 100, "cache ttl in range, got " .. tostring(ttl))
    print("cache ok: ttl=" .. ttl)

    -- counters
    local counter = key("counter")
    client:set(counter, "10")
    assert(client:incr(counter) == 11, "incr")
    assert(client:incrby(counter, 5) == 16, "incrby")
    assert(client:decr(counter) == 15, "decr")
    assert(client:decrby(counter, 5) == 10, "decrby")
    print("counters ok")

    -- a hash modelling a user record
    local user = key("user")
    client:hset(user, "name", "alice", "age", "30", "role", "admin")
    assert(client:hget(user, "name") == "alice", "hget")
    assert(client:hlen(user) == 3, "hlen")
    assert(client:hexists(user, "role") == 1, "hexists")
    client:hdel(user, "age")
    assert(client:hexists(user, "age") == 0, "hdel")
    local flat = client:hgetall(user)
    local fields = {}
    for i = 1, #flat, 2 do
        fields[flat[i]] = flat[i + 1]
    end
    assert(fields.name == "alice" and fields.role == "admin" and fields.age == nil, "hgetall")
    print("hash ok")

    -- a list used as a queue
    local queue = key("queue")
    client:rpush(queue, "a", "b", "c")
    assert(client:llen(queue) == 3, "llen")
    assert(client:lpop(queue) == "a", "lpop")
    assert(client:rpop(queue) == "c", "rpop")
    local rest = client:lrange(queue, 0, -1)
    assert(#rest == 1 and rest[1] == "b", "lrange")
    print("list ok")

    -- a set with membership checks
    local tags = key("tags")
    client:sadd(tags, "x", "y", "z", "x")
    assert(client:scard(tags) == 3, "scard ignores the duplicate")
    assert(client:sismember(tags, "y") == 1, "sismember present")
    assert(client:sismember(tags, "w") == 0, "sismember absent")
    client:srem(tags, "z")
    assert(client:scard(tags) == 2, "srem")
    print("set ok")

    -- a sorted set used as a leaderboard
    local board = key("board")
    client:zadd(board, 100, "alice", 200, "bob", 150, "carol")
    local top = client:zrevrange(board, 0, -1)
    assert(top[1] == "bob" and top[2] == "carol" and top[3] == "alice", "leaderboard order")
    assert(tonumber(client:zscore(board, "bob")) == 200, "zscore")
    assert(client:zrevrank(board, "bob") == 0, "zrevrank leader")
    print("sorted set ok")

    -- a MULTI/EXEC transaction where queued commands answer QUEUED and then EXEC returns every result in order
    local txKey = key("tx")
    assert(client:command("MULTI") == "OK", "multi")
    assert(client:set(txKey, "1") == "QUEUED", "queued set")
    assert(client:incr(txKey) == "QUEUED", "queued incr")
    assert(client:incrby(txKey, 10) == "QUEUED", "queued incrby")
    local results = client:command("EXEC")
    assert(results[1] == "OK" and results[2] == 2 and results[3] == 12, "exec results in order")
    print("MULTI/EXEC ok")

    -- a pipeline issues several commands in one round trip
    local pipeKey = key("pipe")
    local replies = client:pipeline(function(p)
        p:set(pipeKey, "100")
        p:incrby(pipeKey, 5)
        p:get(pipeKey)
    end)
    assert(replies[1] == "OK" and replies[2] == 105 and replies[3] == "105", "pipeline replies")
    print("pipeline ok")

    -- a short expiry actually elapses, with a generous window so a slow round trip to a remote server cannot expire the key before the first check observes it
    local volatile = key("volatile")
    client:set(volatile, "soon", "PX", 600)
    assert(client:exists(volatile) == 1, "exists before expiry")
    async.sleep(900):await()
    assert(client:exists(volatile) == 0, "key expired")
    print("expiry ok")

    -- clean up every key this run created
    client:del(cacheKey, counter, user, queue, tags, board, txKey, pipeKey, volatile)
    client:close()

    -- the multiplexed client opts into auto-pipelining but speaks the same command api
    local mux = redis.connect({ host = HOST, port = PORT, username = USER, password = PASS, pipeline = true })
    assert(mux:command("PING") == "PONG", "mux client reaches the server")

    local muxKey = key("mux")
    assert(mux:set(muxKey, "10") == "OK", "mux set")
    assert(mux:incrby(muxKey, 5) == 15, "mux incrby")
    assert(mux:get(muxKey) == "15", "mux get")

    -- commands issued from concurrent coroutines are batched into one send yet each resolves with its own reply in request order
    local first, second
    local remaining = 2
    async.spawn(function()
        first = mux:get(muxKey)
        remaining = remaining - 1
    end)
    async.spawn(function()
        second = mux:incrby(muxKey, 1)
        remaining = remaining - 1
    end)
    while remaining > 0 do
        async.sleep(1):await()
    end
    assert(first == "15", "the concurrent mux get resolved with its own reply")
    assert(second == 16, "the concurrent mux incrby resolved with its own reply")

    mux:del(muxKey)
    mux:close()
    print("multiplexed client ok")

    print("redis integration ok")
end)
