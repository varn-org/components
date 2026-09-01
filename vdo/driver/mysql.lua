-- mysql/mariadb backend for vdo, binding the c client library through ffi and binding parameters with server-side escaping (mysql_real_escape_string), matching pdo's default emulated-prepare behaviour
local ffi = require("ffi")
local platform = require("platform")
local sql = require("vdo.sql")

ffi.cdef [[
typedef void MYSQL;
typedef void MYSQL_RES;
typedef char **MYSQL_ROW;

typedef struct st_mysql_field {
    char *name;
    char *org_name;
    char *table;
    char *org_table;
    char *db;
    char *catalog;
    char *def;
    unsigned long length;
    unsigned long max_length;
    unsigned int name_length;
    unsigned int org_name_length;
    unsigned int table_length;
    unsigned int org_table_length;
    unsigned int db_length;
    unsigned int catalog_length;
    unsigned int def_length;
    unsigned int flags;
    unsigned int decimals;
    unsigned int charsetnr;
    int type;
    void *extension;
} MYSQL_FIELD;

MYSQL *mysql_init(MYSQL *mysql);
MYSQL *mysql_real_connect(MYSQL *mysql, const char *host, const char *user, const char *passwd,
    const char *db, unsigned int port, const char *unix_socket, unsigned long clientflag);
void mysql_close(MYSQL *sock);
const char *mysql_error(MYSQL *mysql);
int mysql_set_character_set(MYSQL *mysql, const char *csname);
unsigned long mysql_real_escape_string(MYSQL *mysql, char *to, const char *from, unsigned long length);

int mysql_real_query(MYSQL *mysql, const char *q, unsigned long length);
MYSQL_RES *mysql_store_result(MYSQL *mysql);
void mysql_free_result(MYSQL_RES *result);
unsigned long long mysql_num_rows(MYSQL_RES *result);
unsigned int mysql_num_fields(MYSQL_RES *result);
MYSQL_ROW mysql_fetch_row(MYSQL_RES *result);
unsigned long *mysql_fetch_lengths(MYSQL_RES *result);
MYSQL_FIELD *mysql_fetch_fields(MYSQL_RES *result);
unsigned int mysql_field_count(MYSQL *mysql);
unsigned long long mysql_affected_rows(MYSQL *mysql);
unsigned long long mysql_insert_id(MYSQL *mysql);
]]

local MYSQL_TYPE_DECIMAL = 0
local MYSQL_TYPE_TINY = 1
local MYSQL_TYPE_SHORT = 2
local MYSQL_TYPE_LONG = 3
local MYSQL_TYPE_FLOAT = 4
local MYSQL_TYPE_DOUBLE = 5
local MYSQL_TYPE_LONGLONG = 8
local MYSQL_TYPE_INT24 = 9
local MYSQL_TYPE_NEWDECIMAL = 246

local lib

-- cffi returns small 64-bit integers as plain lua numbers but wide ones as cdata, so normalize both
local function asNumber(value)
    if type(value) == "number" then
        return value
    end
    return ffi.tonumber(value)
end

-- a c NULL pointer is never equal to lua nil under cffi, so test it against the null cdata
local function isNull(ptr)
    return ptr == ffi.nullptr
end

local Connection = {}
Connection.__index = Connection

local Statement = {}
Statement.__index = Statement

local function fail(handle, context)
    error("[VdoMysql] " .. context .. ": " .. ffi.string(lib.mysql_error(handle)))
end

-- renders a bound value as a sql literal, escaping strings against the live connection charset
local function literal(handle, value)
    if value == nil then
        return "NULL"
    end

    local kind = type(value)
    if kind == "boolean" then
        return value and "1" or "0"
    end
    if kind == "number" then
        if math.type(value) == "integer" then
            return tostring(value)
        end
        if value ~= value or value == math.huge or value == -math.huge then
            error("[VdoMysql] Cannot bind a non-finite number.")
        end
        -- force a dot decimal separator so a comma locale cannot emit malformed sql like 1,5
        return (string.format("%.17g", value):gsub(",", "."))
    end
    if kind == "string" then
        local buffer = ffi.new("char[?]", #value * 2 + 1)
        local written = lib.mysql_real_escape_string(handle, buffer, value, #value)
        return "'" .. ffi.string(buffer, asNumber(written)) .. "'"
    end

    error("[VdoMysql] Cannot bind value of type " .. kind .. ".")
end

local function decodeCell(fieldType, text)
    if fieldType == MYSQL_TYPE_TINY
        or fieldType == MYSQL_TYPE_SHORT
        or fieldType == MYSQL_TYPE_LONG
        or fieldType == MYSQL_TYPE_LONGLONG
        or fieldType == MYSQL_TYPE_INT24 then
        return math.tointeger(tonumber(text)) or tonumber(text)
    end
    if fieldType == MYSQL_TYPE_FLOAT
        or fieldType == MYSQL_TYPE_DOUBLE
        or fieldType == MYSQL_TYPE_DECIMAL
        or fieldType == MYSQL_TYPE_NEWDECIMAL then
        return tonumber(text)
    end
    return text
end

local function runQuery(handle, text)
    if lib.mysql_real_query(handle, text, #text) ~= 0 then
        fail(handle, "Query")
    end
end

-- buffers the current result client-side so the connection is free for the next statement, returning nil when the statement produced no result set (e.g. an insert or ddl)
local function captureResult(handle)
    local result = lib.mysql_store_result(handle)
    if isNull(result) then
        if lib.mysql_field_count(handle) ~= 0 then
            fail(handle, "Store result")
        end
        return nil
    end

    local fields = {}
    local count = lib.mysql_num_fields(result)
    local meta = lib.mysql_fetch_fields(result)
    for i = 0, count - 1 do
        fields[i] = { name = ffi.string(meta[i].name), type = meta[i].type }
    end

    return { result = result, fields = fields, fieldCount = count }
end

function Statement:clearResult()
    if self.result then
        lib.mysql_free_result(self.result)
        self.result = nil
    end
end

function Statement:execute(params)
    self:clearResult()

    -- interleave the literal chunks with escaped values to form the final statement text
    local parts = { self.parsed.chunks[1] }
    for index = 1, #self.parsed.order do
        parts[#parts + 1] = literal(self.handle, sql.valueFor(self.parsed, params, index))
        parts[#parts + 1] = self.parsed.chunks[index + 1]
    end

    runQuery(self.handle, table.concat(parts))

    local captured = captureResult(self.handle)
    if captured then
        self.result = captured.result
        self.fields = captured.fields
        self.fieldCount = captured.fieldCount
        -- a buffered select reports its retrieved row total
        self.affected = asNumber(lib.mysql_num_rows(captured.result))
    else
        self.fields = nil
        self.fieldCount = 0
        -- a write reports the rows it changed
        self.affected = asNumber(lib.mysql_affected_rows(self.handle))
    end
    return self
end

function Statement:fetch()
    if not self.result then
        return nil
    end

    local row = lib.mysql_fetch_row(self.result)
    if isNull(row) then
        return nil
    end

    local lengths = lib.mysql_fetch_lengths(self.result)
    local out = {}
    for i = 0, self.fieldCount - 1 do
        local field = self.fields[i]
        if isNull(row[i]) then
            out[field.name] = nil
        else
            out[field.name] = decodeCell(field.type, ffi.string(row[i], asNumber(lengths[i])))
        end
    end
    return out
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
    return self.affected or 0
end

function Statement:columnCount()
    return self.fieldCount or 0
end

function Statement:close()
    self:clearResult()
end

-- a statement left unclosed frees its buffered result set when collected, so result memory cannot leak
Statement.__gc = Statement.close

function Connection:prepare(statement)
    return setmetatable({ handle = self.handle, parsed = sql.parse(statement), fieldCount = 0 }, Statement)
end

function Connection:query(statement, params)
    return self:prepare(statement):execute(params or {})
end

function Connection:exec(statement)
    runQuery(self.handle, statement)

    -- discard any result set so the connection is left ready for the next command
    local captured = captureResult(self.handle)
    if captured then
        lib.mysql_free_result(captured.result)
    end

    return asNumber(lib.mysql_affected_rows(self.handle))
end

function Connection:lastInsertId()
    return asNumber(lib.mysql_insert_id(self.handle))
end

function Connection:beginTransaction()
    self:exec("START TRANSACTION")
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
    lib.mysql_close(self.handle)
    self.handle = nil
end

Connection.__gc = Connection.close

local function loadLibrary()
    -- mysql and mariadb ship the same c api under different library names
    for _, name in ipairs({ "mysqlclient", "mariadb" }) do
        local ok, loaded = pcall(ffi.load, platform.libraryFilename(name))
        if ok then
            return loaded
        end
    end
    error("[VdoMysql] Could not load a client library (tried mysqlclient, mariadb).")
end

local driver = {}

function driver.connect(params, username, password)
    lib = lib or loadLibrary()

    local handle = lib.mysql_init(nil)
    if isNull(handle) then
        error("[VdoMysql] Client initialization failed.")
    end

    local port = tonumber(params.port) or 3306
    local connected = lib.mysql_real_connect(
        handle,
        params.host,
        username or params.user,
        password or params.password,
        params.dbname,
        port,
        params.unix_socket,
        0
    )
    if isNull(connected) then
        local message = ffi.string(lib.mysql_error(handle))
        lib.mysql_close(handle)
        error("[VdoMysql] Connect: " .. message)
    end

    -- a known charset keeps escaping correct and text decoding predictable, and since a silent fallback to the server default would leave mysql_real_escape_string interpreting bytes under a different encoding than the application expects, a failure here aborts the connect
    local charset = params.charset or "utf8mb4"
    if lib.mysql_set_character_set(handle, charset) ~= 0 then
        local message = ffi.string(lib.mysql_error(handle))
        lib.mysql_close(handle)
        error("[VdoMysql] Set character set " .. charset .. ": " .. message)
    end

    return setmetatable({ handle = handle }, Connection)
end

return driver
