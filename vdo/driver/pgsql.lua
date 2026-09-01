-- postgres backend for vdo, binding libpq through ffi with real server-side prepared statements
local ffi = require("ffi")
local platform = require("platform")
local sql = require("vdo.sql")

ffi.cdef [[
typedef void PGconn;
typedef void PGresult;

PGconn *PQconnectdb(const char *conninfo);
int PQstatus(const PGconn *conn);
char *PQerrorMessage(const PGconn *conn);
void PQfinish(PGconn *conn);

PGresult *PQexec(PGconn *conn, const char *query);
PGresult *PQprepare(PGconn *conn, const char *stmtName, const char *query, int nParams, const unsigned int *paramTypes);
PGresult *PQexecPrepared(PGconn *conn, const char *stmtName, int nParams,
    const char **paramValues, const int *paramLengths, const int *paramFormats, int resultFormat);

int PQresultStatus(const PGresult *res);
char *PQresultErrorMessage(const PGresult *res);
void PQclear(PGresult *res);

int PQntuples(const PGresult *res);
int PQnfields(const PGresult *res);
char *PQfname(const PGresult *res, int field_num);
unsigned int PQftype(const PGresult *res, int field_num);
char *PQgetvalue(const PGresult *res, int row_number, int field_num);
int PQgetisnull(const PGresult *res, int row_number, int field_num);
char *PQcmdTuples(PGresult *res);
]]

local CONNECTION_OK = 0
local PGRES_COMMAND_OK = 1
local PGRES_TUPLES_OK = 2

local OID_BOOL = 16
local OID_INT8 = 20
local OID_INT2 = 21
local OID_INT4 = 23
local OID_FLOAT4 = 700
local OID_FLOAT8 = 701
local OID_NUMERIC = 1700

local lib

-- a c NULL pointer is never equal to lua nil under cffi, so test it against the null cdata
local function isNull(ptr)
    return ptr == ffi.nullptr
end

local Connection = {}
Connection.__index = Connection

local Statement = {}
Statement.__index = Statement

local function quote(value)
    return "'" .. tostring(value):gsub("\\", "\\\\"):gsub("'", "\\'") .. "'"
end

local function buildConnInfo(params, username, password)
    local pairs_out = {}

    for key, value in pairs(params) do
        if key ~= "driver" then
            pairs_out[#pairs_out + 1] = key .. "=" .. quote(value)
        end
    end
    if username then
        pairs_out[#pairs_out + 1] = "user=" .. quote(username)
    end
    if password then
        pairs_out[#pairs_out + 1] = "password=" .. quote(password)
    end

    return table.concat(pairs_out, " ")
end

-- converts a bound lua value to the text representation libpq expects, or nil for a sql NULL
local function toParamText(value)
    if value == nil then
        return nil
    end

    local kind = type(value)
    if kind == "boolean" then
        return value and "t" or "f"
    end
    if kind == "number" then
        return tostring(value)
    end
    if kind == "string" then
        return value
    end

    error("[VdoPgsql] Cannot bind value of type " .. kind .. ".")
end

local function decodeCell(oid, text)
    if oid == OID_BOOL then
        return text == "t"
    end
    if oid == OID_INT2 or oid == OID_INT4 or oid == OID_INT8 then
        return math.tointeger(tonumber(text)) or tonumber(text)
    end
    if oid == OID_FLOAT4 or oid == OID_FLOAT8 or oid == OID_NUMERIC then
        return tonumber(text)
    end
    return text
end

local function checkResult(conn, result, context)
    if isNull(result) then
        error("[VdoPgsql] " .. context .. ": " .. ffi.string(lib.PQerrorMessage(conn)))
    end

    local status = lib.PQresultStatus(result)
    if status ~= PGRES_COMMAND_OK and status ~= PGRES_TUPLES_OK then
        local message = ffi.string(lib.PQresultErrorMessage(result))
        lib.PQclear(result)
        error("[VdoPgsql] " .. context .. ": " .. message)
    end

    return result
end

-- wraps a tuple result so fetch can walk it row by row, capturing column names and type oids once
local function wrapResult(result)
    local fields = {}
    local count = lib.PQnfields(result)
    for i = 0, count - 1 do
        fields[i] = { name = ffi.string(lib.PQfname(result, i)), oid = lib.PQftype(result, i) }
    end

    return {
        result = result,
        fields = fields,
        fieldCount = count,
        total = lib.PQntuples(result),
        -- empty for a select, the affected total for an insert, update or delete
        affected = tonumber(ffi.string(lib.PQcmdTuples(result))) or 0,
        cursor = 0,
    }
end

function Statement:execute(params)
    if self.cursor then
        self:clearResult()
    end

    -- copy each value into an owned, nul-terminated c buffer and keep it alive for the call, so the pointers handed to libpq never depend on the lifetime of a temporary string conversion
    local count = #self.parsed.order
    local values = ffi.new("const char *[?]", count == 0 and 1 or count)
    local pinned = {}

    for index = 1, count do
        local text = toParamText(sql.valueFor(self.parsed, params, index))
        if text == nil then
            values[index - 1] = nil
        else
            local buffer = ffi.new("char[?]", #text + 1)
            ffi.copy(buffer, text, #text)
            pinned[index] = buffer
            -- cffi does not implicitly decay a char array to const char *, so cast before storing
            values[index - 1] = ffi.cast("const char *", buffer)
        end
    end

    local result = checkResult(
        self.connection.handle,
        lib.PQexecPrepared(self.connection.handle, self.name, count, values, nil, nil, 0),
        "Execute"
    )

    local wrapped = wrapResult(result)
    self.result = wrapped.result
    self.fields = wrapped.fields
    self.fieldCount = wrapped.fieldCount
    self.total = wrapped.total
    self.affected = wrapped.affected
    self.cursor = 0
    return self
end

function Statement:fetch()
    if self.cursor >= self.total then
        return nil
    end

    local rowIndex = self.cursor
    self.cursor = self.cursor + 1

    local row = {}
    for i = 0, self.fieldCount - 1 do
        local field = self.fields[i]
        if lib.PQgetisnull(self.result, rowIndex, i) == 1 then
            row[field.name] = nil
        else
            row[field.name] = decodeCell(field.oid, ffi.string(lib.PQgetvalue(self.result, rowIndex, i)))
        end
    end
    return row
end

function Statement:fetchAll()
    local rows = {}
    while true do
        local row = self:fetch()
        if not row then
            return rows
        end
        rows[#rows + 1] = row
    end
end

function Statement:rowCount()
    -- a select reports its retrieved rows, a write reports the rows it changed
    if self.fieldCount and self.fieldCount > 0 then
        return self.total or 0
    end
    return self.affected or 0
end

function Statement:columnCount()
    return self.fieldCount or 0
end

function Statement:clearResult()
    if self.result then
        lib.PQclear(self.result)
        self.result = nil
    end
end

function Statement:close()
    self:clearResult()

    -- release the server-side prepared statement, but only while the connection is still open so a late gc never touches a finished handle
    if self.name and self.connection and self.connection.handle then
        local deallocated = lib.PQexec(self.connection.handle, "DEALLOCATE " .. self.name)
        if deallocated ~= nil then
            lib.PQclear(deallocated)
        end
    end

    self.name = nil
    self.cursor = nil
end

-- a statement left unclosed frees its result when collected, so result memory cannot leak
Statement.__gc = Statement.close

function Connection:prepare(statement)
    local parsed = sql.parse(statement)

    local ordinal = 0
    local text = sql.build(parsed, function()
        ordinal = ordinal + 1
        return "$" .. ordinal
    end)

    self.counter = self.counter + 1
    local name = "vdo_" .. self.counter

    local prepared = checkResult(self.handle, lib.PQprepare(self.handle, name, text, #parsed.order, nil), "Prepare")
    lib.PQclear(prepared)

    return setmetatable({ connection = self, name = name, parsed = parsed, cursor = 0 }, Statement)
end

function Connection:query(statement, params)
    if params then
        local stmt = self:prepare(statement)
        return stmt:execute(params)
    end

    local result = checkResult(self.handle, lib.PQexec(self.handle, statement), "Query")
    local wrapped = wrapResult(result)
    return setmetatable(wrapped, Statement)
end

function Connection:exec(statement)
    local result = checkResult(self.handle, lib.PQexec(self.handle, statement), "Exec")

    local affected = tonumber(ffi.string(lib.PQcmdTuples(result))) or 0
    lib.PQclear(result)
    return affected
end

function Connection:lastInsertId(sequence)
    -- the sequence name is interpolated into the statement, so reject anything that is not a plain identifier (letters, digits, underscore, dot) before handing it to the server
    if sequence ~= nil then
        if type(sequence) ~= "string" or not sequence:match("^[%w_.]+$") then
            error("[VdoPgsql] The lastInsertId sequence must be a plain identifier.")
        end
    end
    local statement = sequence and ("SELECT currval('" .. sequence .. "')") or "SELECT lastval()"

    local stmt = self:query(statement)
    local row = stmt:fetch()
    stmt:close()

    if not row then
        return nil
    end
    for _, value in pairs(row) do
        return value
    end
end

function Connection:beginTransaction()
    self:exec("BEGIN")
    self.inTx = true
end

function Connection:commit()
    -- clear the flag first so a failed COMMIT never leaves inTransaction() reporting a transaction that is already over
    self.inTx = false
    self:exec("COMMIT")
end

function Connection:rollBack()
    self:exec("ROLLBACK")
    self.inTx = false
end

function Connection:inTransaction()
    return self.inTx == true
end

-- runs fn inside a transaction (committing on success, rolling back and re-raising on any error so a partial change can never be left behind), passing the connection to fn and returning its value
function Connection:transaction(fn)
    self:beginTransaction()

    local ok, result = pcall(fn, self)
    if not ok then
        local rollbackOk, rollbackErr = pcall(function()
            self:rollBack()
        end)
        -- the original error takes priority, with a rollback failure appended so the caller knows the connection may still hold an open transaction on the server
        self.inTx = false
        if not rollbackOk then
            error(tostring(result) .. " | rollback also failed: " .. tostring(rollbackErr), 0)
        end
        error(result, 0)
    end

    self:commit()
    return result
end

function Connection:close()
    if not self.handle then
        return
    end
    lib.PQfinish(self.handle)
    self.handle = nil
end

Connection.__gc = Connection.close

local driver = {}

function driver.connect(params, username, password)
    lib = lib or ffi.load(platform.libraryFilename("pq"))

    local handle = lib.PQconnectdb(buildConnInfo(params, username, password))
    if isNull(handle) then
        error("[VdoPgsql] Connection allocation failed.")
    end

    if lib.PQstatus(handle) ~= CONNECTION_OK then
        local message = ffi.string(lib.PQerrorMessage(handle))
        lib.PQfinish(handle)
        error("[VdoPgsql] Connect: " .. message)
    end

    return setmetatable({ handle = handle, counter = 0 }, Connection)
end

return driver
