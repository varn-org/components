-- sqlite backend for vdo, binding the sqlite3 c api through ffi
local ffi = require("ffi")
local platform = require("platform")
local sql = require("vdo.sql")

ffi.cdef [[
typedef void sqlite3;
typedef void sqlite3_stmt;

int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
int sqlite3_close_v2(sqlite3 *db);
const char *sqlite3_errmsg(sqlite3 *db);

int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
int sqlite3_step(sqlite3_stmt *pStmt);
int sqlite3_reset(sqlite3_stmt *pStmt);
int sqlite3_finalize(sqlite3_stmt *pStmt);

int sqlite3_bind_int64(sqlite3_stmt *pStmt, int i, long long v);
int sqlite3_bind_double(sqlite3_stmt *pStmt, int i, double v);
int sqlite3_bind_text(sqlite3_stmt *pStmt, int i, const char *z, int n, void *xDel);
int sqlite3_bind_null(sqlite3_stmt *pStmt, int i);

int sqlite3_column_count(sqlite3_stmt *pStmt);
int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
long long sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
const void *sqlite3_column_blob(sqlite3_stmt *pStmt, int iCol);
int sqlite3_column_bytes(sqlite3_stmt *pStmt, int iCol);

int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg);
void sqlite3_free(void *p);

int sqlite3_changes(sqlite3 *db);
long long sqlite3_last_insert_rowid(sqlite3 *db);
]]

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_BLOB = 4

local SQLITE_OPEN_READWRITE = 0x00000002
local SQLITE_OPEN_CREATE = 0x00000004

-- forces sqlite to copy bound buffers, so a lua string can be collected right after the bind call
local SQLITE_TRANSIENT = ffi.cast("void *", -1)

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

local function fail(db, context)
    local message = ffi.string(lib.sqlite3_errmsg(db))
    error("[VdoSqlite] " .. context .. ": " .. message)
end

local function bindValue(stmt, db, position, value)
    local kind = type(value)

    if value == nil then
        lib.sqlite3_bind_null(stmt, position)
    elseif kind == "number" then
        if math.type(value) == "integer" then
            lib.sqlite3_bind_int64(stmt, position, value)
        else
            lib.sqlite3_bind_double(stmt, position, value)
        end
    elseif kind == "boolean" then
        lib.sqlite3_bind_int64(stmt, position, value and 1 or 0)
    elseif kind == "string" then
        if lib.sqlite3_bind_text(stmt, position, value, #value, SQLITE_TRANSIENT) ~= SQLITE_OK then
            fail(db, "Bind text")
        end
    else
        error("[VdoSqlite] Cannot bind value of type " .. kind .. ".")
    end
end

local function readColumn(stmt, index)
    local kind = lib.sqlite3_column_type(stmt, index)

    if kind == SQLITE_INTEGER then
        return asNumber(lib.sqlite3_column_int64(stmt, index))
    end
    if kind == SQLITE_FLOAT then
        return lib.sqlite3_column_double(stmt, index)
    end
    if kind == SQLITE_TEXT then
        local pointer = lib.sqlite3_column_text(stmt, index)
        local size = lib.sqlite3_column_bytes(stmt, index)
        return ffi.string(ffi.cast("const char *", pointer), size)
    end
    if kind == SQLITE_BLOB then
        local pointer = lib.sqlite3_column_blob(stmt, index)
        local size = lib.sqlite3_column_bytes(stmt, index)
        return ffi.string(ffi.cast("const char *", pointer), size)
    end

    return nil
end

local function buildRow(stmt)
    local row = {}
    local count = lib.sqlite3_column_count(stmt)
    for i = 0, count - 1 do
        local name = ffi.string(lib.sqlite3_column_name(stmt, i))
        row[name] = readColumn(stmt, i)
    end
    return row
end

function Statement:step()
    local rc = lib.sqlite3_step(self.handle)
    if rc == SQLITE_DONE then
        self.done = true
        return nil
    end
    if rc ~= SQLITE_ROW then
        fail(self.db, "Step")
    end
    return buildRow(self.handle)
end

function Statement:execute(params)
    lib.sqlite3_reset(self.handle)
    self.done = false

    for index = 1, #self.parsed.order do
        bindValue(self.handle, self.db, index, sql.valueFor(self.parsed, params, index))
    end

    -- step once so the statement actually runs now, buffering the first row for fetch
    self.pending = self:step()

    -- sqlite only tracks rows changed by data modification, so this is the affected count for an insert, update or delete rather than a row total for a select, matching pdo's sqlite behaviour
    self.affected = lib.sqlite3_changes(self.db)
    return self
end

function Statement:fetch()
    if self.pending ~= nil then
        local row = self.pending
        self.pending = nil
        return row
    end
    if self.done then
        return nil
    end
    return self:step()
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
    -- for a select this is sqlite's last-changed count rather than the selected-row total, so use #fetchAll() for a portable select count
    return self.affected or 0
end

function Statement:columnCount()
    return lib.sqlite3_column_count(self.handle)
end

function Statement:close()
    if not self.handle then
        return
    end
    lib.sqlite3_finalize(self.handle)
    self.handle = nil
end

-- a statement left unclosed (for example db:query(sql):fetchAll()) is finalized when collected, so a forgotten cursor cannot keep holding a lock on its table
Statement.__gc = Statement.close

local function prepareStatement(self, statement)
    local parsed = sql.parse(statement)
    local text = sql.build(parsed, function()
        return "?"
    end)

    local out = ffi.new("sqlite3_stmt *[1]")
    if lib.sqlite3_prepare_v2(self.handle, text, #text, out, nil) ~= SQLITE_OK then
        fail(self.handle, "Prepare")
    end

    return setmetatable({ db = self.handle, handle = out[0], parsed = parsed, done = false }, Statement)
end

function Connection:prepare(statement)
    return prepareStatement(self, statement)
end

function Connection:query(statement, params)
    local stmt = prepareStatement(self, statement)
    return stmt:execute(params)
end

function Connection:exec(statement)
    -- sqlite3_exec runs every statement in the string, so a multi-statement script is not silently truncated to its first command like a single prepared step would be
    local errmsg = ffi.new("char *[1]")
    if lib.sqlite3_exec(self.handle, statement, nil, nil, errmsg) ~= SQLITE_OK then
        local message = not isNull(errmsg[0]) and ffi.string(errmsg[0]) or ffi.string(lib.sqlite3_errmsg(self.handle))
        if not isNull(errmsg[0]) then
            lib.sqlite3_free(errmsg[0])
        end
        error("[VdoSqlite] Exec: " .. message)
    end

    return lib.sqlite3_changes(self.handle)
end

function Connection:lastInsertId()
    return asNumber(lib.sqlite3_last_insert_rowid(self.handle))
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
    lib.sqlite3_close_v2(self.handle)
    self.handle = nil
end

Connection.__gc = Connection.close

local driver = {}

function driver.connect(params)
    lib = lib or ffi.load(platform.libraryFilename("sqlite3"))

    local path = params.path
    if path == nil or path == "" then
        error("[VdoSqlite] DSN must provide a database path or :memory:.")
    end

    local out = ffi.new("sqlite3 *[1]")
    local flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
    if lib.sqlite3_open_v2(path, out, flags, nil) ~= SQLITE_OK then
        local db = out[0]
        local message = not isNull(db) and ffi.string(lib.sqlite3_errmsg(db)) or "unknown error"
        if not isNull(db) then
            lib.sqlite3_close_v2(db)
        end
        error("[VdoSqlite] Open: " .. message)
    end

    return setmetatable({ handle = out[0] }, Connection)
end

return driver
