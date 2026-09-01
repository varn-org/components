-- redis client built on the native socket module speaking RESP2 over a single connection.
-- every socket operation yields on the event loop so the whole lifecycle must run inside an async coroutine.
-- with no __gc finalizer a forgotten client leaks until the runtime exits since :close() cannot run outside an async coroutine.
-- always close in the same scope that opened the client, ideally via pcall to cover the error path.
local socket = require("socket")
local async = require("async")

local READ_CHUNK = 4096

-- a server error reply is represented as a value instead of raised mid-parse so an error nested in an array does not desync the stream.
-- command() raises only when the top-level reply is an error.
local function makeServerError(message)
    return setmetatable({ message = message }, { __index = { isRedisError = true } })
end

local function isServerError(value)
    return type(value) == "table" and getmetatable(value) ~= nil and value.isRedisError == true
end

-- a buffered reader gives RESP framing exact byte counts and crlf-terminated lines since socket:receive returns only up to n bytes
local Reader = {}
Reader.__index = Reader

function Reader.new(sock)
    return setmetatable({ sock = sock, buffer = "", cursor = 1 }, Reader)
end

function Reader:pull()
    local chunk, err = self.sock:receive(READ_CHUNK):await()
    if err then
        error("[Redis] Receive failed: " .. tostring(err))
    end
    if chunk == "" then
        error("[Redis] Connection closed by server.")
    end

    -- drop the already-consumed prefix before appending so the buffer stays bounded
    if self.cursor > 1 then
        self.buffer = self.buffer:sub(self.cursor)
        self.cursor = 1
    end
    self.buffer = self.buffer .. chunk
end

function Reader:line()
    while true do
        local stop = self.buffer:find("\r\n", self.cursor, true)
        if stop then
            local line = self.buffer:sub(self.cursor, stop - 1)
            self.cursor = stop + 2
            return line
        end
        self:pull()
    end
end

function Reader:bytes(count)
    while (#self.buffer - self.cursor + 1) < count do
        self:pull()
    end

    local data = self.buffer:sub(self.cursor, self.cursor + count - 1)
    self.cursor = self.cursor + count
    return data
end

-- mirrors the redis proto-max-bulk-len ceiling so a corrupt or hostile length prefix cannot drive the client to exhaust memory
local kMaxBulkBytes = 512 * 1024 * 1024

function Reader:reply()
    local line = self:line()
    local kind = line:sub(1, 1)
    local rest = line:sub(2)

    if kind == "+" then
        return rest
    end
    if kind == "-" then
        return makeServerError(rest)
    end
    if kind == ":" then
        return tonumber(rest)
    end

    if kind == "$" then
        local length = tonumber(rest)
        if length == -1 then
            return nil
        end
        if not length or length < 0 or length > kMaxBulkBytes then
            error("[Redis] Invalid bulk length: " .. tostring(rest))
        end
        local data = self:bytes(length)
        self:line()
        return data
    end

    if kind == "*" then
        local count = tonumber(rest)
        if count == -1 then
            return nil
        end
        local items = {}
        for i = 1, count do
            items[i] = self:reply()
        end
        return items
    end

    error("[Redis] Unexpected reply type: " .. tostring(line))
end

-- real methods live in a separate table so __index can fall through to dynamic command dispatch
local methods = {}

local Client = {}
Client.__index = function(_, key)
    local method = methods[key]
    if method then
        return method
    end

    -- any other access becomes a redis command named after the key (redis names are case-insensitive)
    return function(self, ...)
        return self:command(key, ...)
    end
end

local function encodeArgument(value)
    local kind = type(value)
    if kind == "string" then
        return value
    end
    if kind == "number" then
        return tostring(value)
    end
    error("[Redis] Command arguments must be string or number, got " .. kind .. ".")
end

-- encodes one command as a RESP array of bulk strings
local function encodeCommand(...)
    local args = table.pack(...)
    if args.n == 0 then
        error("[Redis] Command requires at least the command name.")
    end

    local parts = { "*" .. args.n .. "\r\n" }
    for i = 1, args.n do
        local arg = encodeArgument(args[i])
        parts[#parts + 1] = "$" .. #arg .. "\r\n" .. arg .. "\r\n"
    end
    return table.concat(parts)
end

function methods:command(...)
    if self.dead then
        error("[Redis] Connection is poisoned after an earlier I/O failure and cannot be reused.")
    end

    local _, err = self.sock:send(encodeCommand(...)):await()
    if err then
        -- a send failure can leave a partial frame on the wire, so the connection is unsafe to reuse
        self.dead = true
        error("[Redis] Send failed: " .. tostring(err))
    end

    -- any throw from the parser means the byte stream is unsynchronized so the connection is marked dead before re-raising, whereas a clean server error reply leaves the stream synchronized and is not poisoning
    local parseOk, reply = pcall(self.reader.reply, self.reader)
    if not parseOk then
        self.dead = true
        error(reply, 0)
    end

    if isServerError(reply) then
        error("[Redis] " .. reply.message)
    end
    return reply
end

-- a pipeline records commands without sending, then flushes them in one write and reads every reply in order via the same dynamic dispatch where p:set(...) and p:get(...) queue their commands
local pipelineMethods = {}

local Pipeline = {}
Pipeline.__index = function(_, key)
    local method = pipelineMethods[key]
    if method then
        return method
    end

    return function(self, ...)
        return self:command(key, ...)
    end
end

function pipelineMethods:command(...)
    self.frames[#self.frames + 1] = encodeCommand(...)
    self.count = self.count + 1
end

function methods:pipeline(builder)
    if self.dead then
        error("[Redis] Connection is poisoned after an earlier I/O failure and cannot be reused.")
    end

    local batch = setmetatable({ frames = {}, count = 0 }, Pipeline)
    builder(batch)

    if batch.count == 0 then
        return {}
    end

    local _, err = self.sock:send(table.concat(batch.frames)):await()
    if err then
        self.dead = true
        error("[Redis] Pipeline send failed: " .. tostring(err))
    end

    -- read every reply before raising so a single server error cannot desync the stream, whereas a parser throw means the bytes after the failed reply are unrecoverable
    local replies = {}
    local firstError
    for i = 1, batch.count do
        local parseOk, reply = pcall(self.reader.reply, self.reader)
        if not parseOk then
            self.dead = true
            error(reply, 0)
        end
        if isServerError(reply) then
            replies[i] = nil
            firstError = firstError or reply.message
        else
            replies[i] = reply
        end
    end

    if firstError then
        error("[Redis] " .. firstError)
    end
    return replies
end

function methods:close()
    if not self.sock then
        return
    end
    self.sock:close():await()
    self.sock = nil
end

-- a multiplexed client shares one connection across many concurrent commands, the ioredis model.
-- each command queues its frame and awaits a per-command deferred.
-- a writer coroutine batches everything queued into a single send for auto-pipelining.
-- a reader coroutine resolves the awaiting commands as replies arrive in request order.
-- opt in with redis.connect({ pipeline = true }).
local muxMethods = {}

local MuxClient = {}
MuxClient.__index = function(_, key)
    local method = muxMethods[key]
    if method then
        return method
    end

    return function(self, ...)
        return self:command(key, ...)
    end
end

local function failPending(self, message)
    self.dead = true

    for _, entry in ipairs(self.pending) do
        entry.err = message
        entry.wake()
    end
    self.pending = {}

    for _, item in ipairs(self.writeQueue) do
        item.entry.err = message
        item.entry.wake()
    end
    self.writeQueue = {}
end

function muxMethods:command(...)
    if self.dead then
        error("[Redis] Connection is poisoned after an earlier I/O failure and cannot be reused.")
    end

    local entry = {}
    entry.gate, entry.wake = async.deferred()
    self.writeQueue[#self.writeQueue + 1] = { frame = encodeCommand(...), entry = entry }

    if self.writerWake then
        local wake = self.writerWake
        self.writerWake = false
        wake()
    end

    entry.gate:await()

    if entry.err then
        error(entry.err, 0)
    end
    if isServerError(entry.reply) then
        error("[Redis] " .. entry.reply.message)
    end
    return entry.reply
end

local function startMux(self)
    -- the writer drains the queue into one send so a burst of concurrent commands costs a single syscall
    async.spawn(function()
        while not self.closed do
            if #self.writeQueue == 0 then
                local gate
                gate, self.writerWake = async.deferred()
                gate:await()
            else
                local batch = self.writeQueue
                self.writeQueue = {}

                local frames = {}
                for i = 1, #batch do
                    frames[i] = batch[i].frame
                    self.pending[#self.pending + 1] = batch[i].entry
                end

                local _, err = self.sock:send(table.concat(frames)):await()
                if err then
                    failPending(self, "[Redis] Send failed: " .. tostring(err))
                    return
                end
            end
        end
    end)

    -- the reader sees replies in request order so each one resolves the oldest awaiting command
    async.spawn(function()
        while not self.closed do
            local ok, reply = pcall(self.reader.reply, self.reader)
            local entry = table.remove(self.pending, 1)
            if not entry then
                -- a reply with nothing pending is an unsolicited frame this request-response client cannot place, so poison the connection instead of leaving later commands unanswered
                self.dead = true
                failPending(self, ok and "[Redis] Received an unsolicited reply." or tostring(reply))
                return
            end

            if ok then
                entry.reply = reply
            else
                entry.err = tostring(reply)
            end
            entry.wake()

            if not ok then
                failPending(self, tostring(reply))
                return
            end
        end
    end)
end

function muxMethods:close()
    self.closed = true
    if self.writerWake then
        local wake = self.writerWake
        self.writerWake = false
        wake()
    end

    -- reject every queued and in-flight command so their awaiting coroutines stop waiting instead of hanging forever
    failPending(self, "[Redis] Connection closed.")

    if self.sock then
        pcall(function()
            self.sock:close():await()
        end)
        self.sock = nil
    end
end

local redis = {}

-- opens the raw transport, negotiating tls first when the client opted in with tls = true
local function connectSocket(options, host, port)
    if options.tls then
        return socket.tls.connect(host, port, { insecure = options.insecure }):await()
    end

    return socket.tcp.connect(host, port):await()
end

-- opens one endpoint and brings it fully online (auth and database select), with any failure closing the socket and propagating so the caller can move on to the next endpoint
local function dial(options, host, port)
    local sock, err = connectSocket(options, host, port)
    if err then
        error("[Redis] Connect to " .. host .. ":" .. port .. " failed: " .. tostring(err), 0)
    end

    -- dead must be a real field because __index turns any missing key into a command.
    -- without it the very first `self.dead` check would dispatch a bogus command and read as truthy.
    local client = setmetatable({ sock = sock, reader = Reader.new(sock), dead = false }, Client)

    local ok, handshakeError = pcall(function()
        -- authenticate before anything else so a wrong credential fails fast
        if options.username then
            client:command("AUTH", options.username, options.password or "")
        elseif options.password then
            client:command("AUTH", options.password)
        end

        if options.db then
            client:command("SELECT", options.db)
        end
    end)

    if not ok then
        client:close()
        error(handshakeError, 0)
    end

    return client
end

-- the multiplexed variant of dial brings the writer/reader loops up first.
-- then it runs the auth and database-select handshake through them like any other command.
local function dialMux(options, host, port)
    local sock, err = connectSocket(options, host, port)
    if err then
        error("[Redis] Connect to " .. host .. ":" .. port .. " failed: " .. tostring(err), 0)
    end

    local client = setmetatable({
        sock = sock,
        reader = Reader.new(sock),
        writeQueue = {},
        pending = {},
        dead = false,
        closed = false,
        writerWake = false,
    }, MuxClient)

    startMux(client)

    local ok, handshakeError = pcall(function()
        if options.username then
            client:command("AUTH", options.username, options.password or "")
        elseif options.password then
            client:command("AUTH", options.password)
        end

        if options.db then
            client:command("SELECT", options.db)
        end
    end)

    if not ok then
        client:close()
        error(handshakeError, 0)
    end

    return client
end

-- connects to the first reachable endpoint, taking a single host/port or a list of { host, port } tables in `hosts` for failover where each is tried in order until one connects and answers.
-- with pipeline = true the connection is multiplexed so concurrent commands share it.
function redis.connect(options)
    options = options or {}

    local dialer = options.pipeline and dialMux or dial
    local endpoints = options.hosts or { { host = options.host, port = options.port } }

    local failures = {}
    for _, endpoint in ipairs(endpoints) do
        local host = endpoint.host or "127.0.0.1"
        local port = endpoint.port or 6379

        local ok, result = pcall(dialer, options, host, port)
        if ok then
            return result
        end
        failures[#failures + 1] = tostring(result)
    end

    error("[Redis] Could not connect to any endpoint: " .. table.concat(failures, "; "))
end

return redis
