-- assert-based test for env covering file parsing, typed accessors, required/missing handling, and that a real environment value is never shadowed by the file
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local env = require("env")

local tmp = os.tmpname()
local file = assert(io.open(tmp, "w"))
file:write("# a comment line\n")
file:write("\n")
file:write("NAME = alice\n")
file:write('GREETING="hello world"\n')
file:write("COUNT=42\n")
file:write("FLAG=yes\n")
file:write("OFF=0\n")
file:write("export REGION='eu-west-1'\n")
file:write("not a valid line without equals\n")
-- PATH is virtually always present in the real environment so the file must not shadow it
file:write("PATH=should-not-win\n")
file:close()

local applied = env.load(tmp)
os.remove(tmp)

-- string values with quotes stripped and whitespace trimmed
assert(env.get("NAME") == "alice", "trimmed string")
assert(env.get("GREETING") == "hello world", "double-quoted value")
assert(env.get("REGION") == "eu-west-1", "single-quoted value with export prefix")

-- comments, blank lines, and malformed lines are skipped
assert(applied["not a valid line without equals"] == nil, "malformed line skipped")

-- typed accessors
assert(env.int("COUNT") == 42, "int parse")
assert(env.int("MISSING_INT", 7) == 7, "int default")
assert(env.bool("FLAG") == true, "bool yes is true")
assert(env.bool("OFF") == false, "bool 0 is false")
assert(env.bool("MISSING_BOOL", true) == true, "bool default")

-- defaults and required
assert(env.get("MISSING", "fallback") == "fallback", "get default")
local ok = pcall(env.require, "DEFINITELY_MISSING")
assert(not ok, "require raises on missing")
assert(env.require("NAME") == "alice", "require returns present value")

-- the real environment wins over a loaded file
if os.getenv("PATH") ~= nil then
    assert(env.get("PATH") ~= "should-not-win", "real environment is not shadowed by the file")
end

-- a missing file is not an error
local none = env.load(dir .. "/does-not-exist.env")
assert(type(none) == "table" and next(none) == nil, "missing file loads nothing")

-- bad typed values raise
local badTmp = os.tmpname()
local bad = assert(io.open(badTmp, "w"))
bad:write("PORT=not-a-number\n")
bad:write("ENABLED=maybe\n")
bad:close()
env.load(badTmp)
os.remove(badTmp)
assert(not pcall(env.int, "PORT"), "non-integer raises")
assert(not pcall(env.bool, "ENABLED"), "non-boolean raises")

print("env integration ok")
