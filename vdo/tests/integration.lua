-- real-application integration test for vdo modelled as a small banking ledger, exercising schema with constraints, reused prepared statements, atomic money transfers, rollback on a constraint violation, parameter binding against injection, aggregates, null handling, and last insert ids, where in-memory sqlite always runs and VDO_MYSQL_DSN / VDO_PGSQL_DSN (with matching _USER / _PASS) add those backends under the same assertions on every driver
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local vdo = require("vdo")

-- each backend needs its own auto-increment column syntax for the last-insert-id check
local AUTO_PK = {
    sqlite = "INTEGER PRIMARY KEY AUTOINCREMENT",
    mysql = "INTEGER AUTO_INCREMENT PRIMARY KEY",
    pgsql = "SERIAL PRIMARY KEY",
}

-- one-shot read helpers that always close the statement, so no cursor is left open
local function scalar(db, sql)
    local stmt = db:query(sql)
    local row = stmt:fetch()
    stmt:close()
    return row
end

local function allRows(db, sql)
    local stmt = db:query(sql)
    local rows = stmt:fetchAll()
    stmt:close()
    return rows
end

local function sumBalances(db)
    return scalar(db, "SELECT COALESCE(SUM(balance), 0) AS total FROM accounts").total
end

local function balanceOf(db, id)
    local stmt = db:prepare("SELECT balance FROM accounts WHERE id = ?")
    stmt:execute({ id })
    local row = stmt:fetch()
    stmt:close()
    return row and row.balance
end

-- moves money atomically where the debit, guarded by a CHECK (balance >= 0), fails the whole transaction when funds are short, so neither side is left changed
local function transfer(db, fromId, toId, amount)
    return db:transaction(function(tx)
        local debit = tx:prepare("UPDATE accounts SET balance = balance - ? WHERE id = ?")
        debit:execute({ amount, fromId })
        assert(debit:rowCount() == 1, "debit must touch exactly one row")
        debit:close()

        local credit = tx:prepare("UPDATE accounts SET balance = balance + ? WHERE id = ?")
        credit:execute({ amount, toId })
        assert(credit:rowCount() == 1, "credit must touch exactly one row")
        credit:close()

        return amount
    end)
end

local function run(target)
    print("== " .. target.label .. " ==")
    local db = vdo.connect(target.dsn, target.user, target.pass)

    -- a constrained schema, like a real ledger
    db:exec("DROP TABLE IF EXISTS accounts")
    db:exec([[
        CREATE TABLE accounts (
            id INTEGER PRIMARY KEY,
            owner VARCHAR(64) NOT NULL,
            balance INTEGER NOT NULL CHECK (balance >= 0)
        )
    ]])

    -- seed two accounts through one reused prepared statement
    local seed = db:prepare("INSERT INTO accounts (id, owner, balance) VALUES (?, ?, ?)")
    seed:execute({ 1, "alice", 1000 })
    assert(seed:rowCount() == 1, "seed alice")
    seed:execute({ 2, "bob", 500 })
    assert(seed:rowCount() == 1, "seed bob")
    seed:close()
    assert(sumBalances(db) == 1500, "opening total")

    -- a successful transfer commits and conserves the total
    local moved = transfer(db, 1, 2, 300)
    assert(moved == 300, "transfer returns its amount")
    assert(balanceOf(db, 1) == 700, "alice debited")
    assert(balanceOf(db, 2) == 800, "bob credited")
    assert(sumBalances(db) == 1500, "total conserved after transfer")
    print("  transfer ok: alice=700 bob=800")

    -- an overdraft trips the CHECK, the transaction rolls back, and nothing changes
    local ok, err = pcall(transfer, db, 2, 1, 5000)
    assert(not ok, "overdraft must fail")
    assert(balanceOf(db, 1) == 700 and balanceOf(db, 2) == 800, "balances unchanged after rollback")
    assert(sumBalances(db) == 1500, "total conserved after failed transfer")
    assert(not db:inTransaction(), "no transaction left open after rollback")
    print("  overdraft rolled back atomically")

    -- a bound parameter is data and never sql, so a classic injection string round-trips intact and the table it tries to drop is still there afterwards
    local payload = "robert'); DROP TABLE accounts;--"
    local inject = db:prepare("INSERT INTO accounts (id, owner, balance) VALUES (?, ?, ?)")
    inject:execute({ 3, payload, 0 })
    inject:close()

    local lookup = db:prepare("SELECT owner FROM accounts WHERE owner = ?")
    lookup:execute({ payload })
    local found = lookup:fetch()
    lookup:close()
    assert(found and found.owner == payload, "injection payload stored and matched as literal data")
    assert(sumBalances(db) == 1500, "accounts table survived the injection attempt")
    print("  sql injection neutralized")

    -- aggregates over the current rows
    local stats = scalar(db, "SELECT COUNT(*) AS n, MIN(balance) AS lo, MAX(balance) AS hi FROM accounts")
    assert(stats.n == 3 and stats.lo == 0 and stats.hi == 800, "aggregate stats")
    print(string.format("  aggregates: n=%d lo=%d hi=%d", stats.n, stats.lo, stats.hi))

    -- a multi-condition parameterized query with ordering
    local q = db:prepare("SELECT owner, balance FROM accounts WHERE balance >= ? AND owner <> ? ORDER BY balance DESC")
    q:execute({ 1, "alice" })
    local rows = q:fetchAll()
    assert(q:rowCount() == 1 and rows[1].owner == "bob", "filtered ordered query")
    q:close()

    -- a nullable column round-trips a real value and a NULL
    db:exec("DROP TABLE IF EXISTS notes")
    db:exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body VARCHAR(64))")
    local note = db:prepare("INSERT INTO notes (id, body) VALUES (?, ?)")
    note:execute({ 1, "hello" })
    note:execute({ 2, nil })
    note:close()
    local noteRows = allRows(db, "SELECT id, body FROM notes ORDER BY id")
    assert(noteRows[1].body == "hello" and noteRows[2].body == nil, "null column round-trip")
    print("  null handling ok")

    -- auto-increment ids reported by lastInsertId
    db:exec("DROP TABLE IF EXISTS events")
    db:exec("CREATE TABLE events (id " .. AUTO_PK[target.driver] .. ", label VARCHAR(32) NOT NULL)")
    local ev = db:prepare("INSERT INTO events (label) VALUES (?)")
    ev:execute({ "first" })
    local firstId = db:lastInsertId()
    ev:execute({ "second" })
    local secondId = db:lastInsertId()
    ev:close()
    assert(secondId == firstId + 1, "lastInsertId advances by one")
    print(string.format("  lastInsertId: %s then %s", tostring(firstId), tostring(secondId)))

    -- a bulk load inside one explicit transaction, then a rolled-back batch that leaves no trace
    db:beginTransaction()
    local bulk = db:prepare("INSERT INTO events (label) VALUES (?)")
    for i = 1, 50 do
        bulk:execute({ "bulk-" .. i })
    end
    bulk:close()
    db:commit()
    assert(scalar(db, "SELECT COUNT(*) AS n FROM events").n == 52, "bulk committed")

    db:beginTransaction()
    db:exec("DELETE FROM events")
    db:rollBack()
    assert(scalar(db, "SELECT COUNT(*) AS n FROM events").n == 52, "delete rolled back")
    print("  bulk insert + rollback ok")

    db:exec("DROP TABLE accounts")
    db:exec("DROP TABLE notes")
    db:exec("DROP TABLE events")
    db:close()
    print("  " .. target.label .. " passed")
end

local targets = {
    { label = "sqlite", driver = "sqlite", dsn = "sqlite::memory:" },
}

if os.getenv("VDO_MYSQL_DSN") then
    targets[#targets + 1] = {
        label = "mysql",
        driver = "mysql",
        dsn = os.getenv("VDO_MYSQL_DSN"),
        user = os.getenv("VDO_MYSQL_USER"),
        pass = os.getenv("VDO_MYSQL_PASS"),
    }
end

if os.getenv("VDO_PGSQL_DSN") then
    targets[#targets + 1] = {
        label = "pgsql",
        driver = "pgsql",
        dsn = os.getenv("VDO_PGSQL_DSN"),
        user = os.getenv("VDO_PGSQL_USER"),
        pass = os.getenv("VDO_PGSQL_PASS"),
    }
end

for _, target in ipairs(targets) do
    run(target)
end

print("vdo integration ok (" .. #targets .. " backend(s))")
