-- vdo (varn data objects) is a pdo-style facade over sqlite, mysql/mariadb, and postgres, implemented in lua on top of the native ffi module, with the driver chosen from the DSN scheme
local dsn = require("vdo.dsn")

-- drivers are required lazily so loading vdo never forces a client library that is not installed
local loaders = {
    sqlite = function()
        return require("vdo.driver.sqlite")
    end,
    mysql = function()
        return require("vdo.driver.mysql")
    end,
    pgsql = function()
        return require("vdo.driver.pgsql")
    end,
}

local vdo = {}

function vdo.connect(source, username, password, options)
    local params = dsn.parse(source)

    local loader = loaders[params.driver]
    if not loader then
        error("[Vdo] No driver registered for: " .. tostring(params.driver))
    end

    return loader().connect(params, username, password, options or {})
end

return vdo
