-- driver-agnostic crud walkthrough where the same code runs against any backend the dsn selects, defaulting to an in-memory sqlite database so it runs anywhere with no server unless VDO_DSN (and optionally VDO_USER / VDO_PASS) targets mysql or postgres instead
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local vdo = require("vdo")

local dsn = os.getenv("VDO_DSN") or "sqlite::memory:"
local db = vdo.connect(dsn, os.getenv("VDO_USER"), os.getenv("VDO_PASS"))

db:exec("DROP TABLE IF EXISTS users")
db:exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL, score REAL NOT NULL)")

-- a prepared insert bound by name, reused for several rows
local insert = db:prepare("INSERT INTO users (name, score) VALUES (:name, :score)")
insert:execute({ name = "alice", score = 9.5 })
insert:execute({ name = "bob", score = 7.25 })
insert:execute({ name = "carol", score = 8.0 })
insert:close()

print("last insert id:", db:lastInsertId())

-- a positional query reads back the rows above a threshold
local query = db:prepare("SELECT id, name, score FROM users WHERE score >= ? ORDER BY score DESC")
query:execute({ 8.0 })
for _, row in ipairs(query:fetchAll()) do
    print(string.format("user %d: %-6s %.2f", row.id, row.name, row.score))
end
query:close()

-- a transaction groups several writes atomically, and rowCount reports the rows it changed
db:beginTransaction()
local bump = db:prepare("UPDATE users SET score = score + 0.5")
bump:execute({})
print("rows updated:", bump:rowCount())
bump:close()
db:commit()

local total = db:query("SELECT count(*) AS n, avg(score) AS avg FROM users"):fetch()
print(string.format("rows: %d  average: %.3f", total.n, total.avg))

db:close()
print("vdo crud ok")
