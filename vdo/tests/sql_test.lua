-- pure-lua unit tests for the vdo sql placeholder parser covering positional and named markers, quoted literals and identifiers with doubled-quote escaping, backtick identifiers, line and block comments, the postgres cast operator, and the build and valueFor helpers
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local sql = require("vdo.sql")

local function orderOf(statement)
    return sql.parse(statement).order
end

local function same(a, b)
    if #a ~= #b then
        return false
    end
    for i = 1, #a do
        if a[i] ~= b[i] then
            return false
        end
    end
    return true
end

-- positional and named markers are collected in order
assert(same(orderOf("SELECT * FROM t WHERE a = ? AND b = ?"), { 1, 2 }), "positional markers")
assert(same(orderOf("SELECT * FROM t WHERE a = :id AND b = :name"), { "id", "name" }), "named markers")
assert(same(orderOf("SELECT :id, ? FROM t"), { "id", 1 }), "mixed markers keep their kinds and order")

-- a marker inside a quoted literal or identifier is not a placeholder
assert(same(orderOf("SELECT a WHERE a = 'hello?world' AND b = ?"), { 1 }), "question mark inside a single-quoted literal is text")
assert(same(orderOf("SELECT a WHERE a = 'it''s :not a marker?' AND b = ?"), { 1 }), "doubled-quote escaping keeps the literal intact")
assert(same(orderOf('SELECT "col?name" FROM t WHERE a = ?'), { 1 }), "question mark inside a double-quoted identifier is text")
assert(same(orderOf("SELECT `weird?col` FROM t WHERE a = ? AND c = :name"), { 1, "name" }), "markers inside a backtick identifier are ignored")

-- a marker inside a comment is not a placeholder
assert(same(orderOf("SELECT ? -- trailing ? and :name\nFROM t"), { 1 }), "line comment markers are ignored")
assert(same(orderOf("SELECT ? /* block ? :name */ FROM t"), { 1 }), "block comment markers are ignored")

-- the postgres cast operator is not mistaken for a named marker
assert(same(orderOf("SELECT a::int FROM t WHERE b = ?"), { 1 }), "the :: cast is preserved")

-- chunks and order stay consistent so the statement can be rebuilt
local parsed = sql.parse("a = ? AND b = :name")
assert(#parsed.chunks == #parsed.order + 1, "chunks always outnumber order by one")
assert(sql.build(parsed, function(index) return "$" .. index end) == "a = $1 AND b = $2", "build substitutes native placeholders in order")

-- valueFor resolves both positional arrays and named maps
assert(sql.valueFor(parsed, { 7, name = "bob" }, 1) == 7, "positional slot binds by number")
assert(sql.valueFor(parsed, { 7, name = "bob" }, 2) == "bob", "named slot binds by key")
assert(not pcall(function() return sql.valueFor(parsed, nil, 1) end), "a nil params table is rejected")

print("vdo sql ok")
