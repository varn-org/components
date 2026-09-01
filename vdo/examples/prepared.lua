-- shows a single prepared statement reused across many executions plus row-at-a-time fetching, defaulting to in-memory sqlite unless VDO_DSN overrides it for another backend
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local vdo = require("vdo")

local db = vdo.connect(os.getenv("VDO_DSN") or "sqlite::memory:", os.getenv("VDO_USER"), os.getenv("VDO_PASS"))

db:exec("DROP TABLE IF EXISTS events")
db:exec("CREATE TABLE events (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, value INTEGER NOT NULL)")

-- one prepared insert drives the whole seed loop
local insert = db:prepare("INSERT INTO events (kind, value) VALUES (?, ?)")
for i = 1, 6 do
    insert:execute({ i % 2 == 0 and "even" or "odd", i })
end
insert:close()

-- the same select is re-executed with different bound values
local byKind = db:prepare("SELECT value FROM events WHERE kind = ? ORDER BY value")
for _, kind in ipairs({ "odd", "even" }) do
    byKind:execute({ kind })

    local values = {}
    while true do
        local row = byKind:fetch()
        if not row then
            break
        end
        values[#values + 1] = row.value
    end

    print(kind, table.concat(values, ", "))
end
byKind:close()

db:close()
print("vdo prepared ok")
