-- pure-lua unit tests for the vdo dsn parser covering sqlite paths, mysql/mariadb and postgres key-value forms, and the malformed, missing-scheme, unsupported-scheme and non-string error paths
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local dsn = require("vdo.dsn")

-- sqlite keeps the remainder verbatim as a path or the memory token
local sqlite = dsn.parse("sqlite:/var/data/app.db")
assert(sqlite.driver == "sqlite" and sqlite.path == "/var/data/app.db", "sqlite path is preserved")
assert(dsn.parse("sqlite3::memory:").path == ":memory:", "the sqlite3 alias and :memory: token are preserved")

-- mysql and mariadb parse key-value segments and tag the driver
local mysql = dsn.parse("mysql:host=localhost;port=3306;user=root;dbname=test")
assert(mysql.driver == "mysql", "mysql scheme maps to the mysql driver")
assert(mysql.host == "localhost" and mysql.port == "3306" and mysql.user == "root" and mysql.dbname == "test", "mysql key-values parse")
assert(dsn.parse("mariadb:host=db").driver == "mysql", "mariadb aliases to the mysql driver")

-- every postgres scheme maps to the pgsql driver
assert(dsn.parse("pgsql:host=db").driver == "pgsql", "pgsql scheme maps to pgsql")
assert(dsn.parse("postgres:host=db").driver == "pgsql", "postgres scheme maps to pgsql")
assert(dsn.parse("postgresql:host=db").driver == "pgsql", "postgresql scheme maps to pgsql")

-- error paths
assert(not pcall(dsn.parse, "mysql:host=localhost;garbage"), "a segment without a key=value is malformed")
assert(not pcall(dsn.parse, "no-scheme-here"), "a dsn without a scheme is rejected")
assert(not pcall(dsn.parse, "oracle:host=db"), "an unsupported scheme is rejected")
assert(not pcall(dsn.parse, 123), "a non-string dsn is rejected")

print("vdo dsn ok")
