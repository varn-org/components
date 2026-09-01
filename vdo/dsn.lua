-- parses a pdo-style data source name into a driver key plus connection parameters
local dsn = {}

local function parseKeyValues(body)
    local params = {}
    for pair in body:gmatch("[^;]+") do
        local key, value = pair:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if not key then
            error("[VdoDsn] Malformed DSN segment: " .. pair)
        end
        params[key] = value
    end
    return params
end

function dsn.parse(source)
    if type(source) ~= "string" then
        error("[VdoDsn] DSN must be a string.")
    end

    local scheme, body = source:match("^(%a[%w]*):(.*)$")
    if not scheme then
        error("[VdoDsn] Missing scheme in DSN: " .. source)
    end
    scheme = scheme:lower()

    -- sqlite keeps the remainder verbatim as a filesystem path or the :memory: token
    if scheme == "sqlite" or scheme == "sqlite3" then
        return { driver = "sqlite", path = body }
    end

    if scheme == "mysql" or scheme == "mariadb" then
        local params = parseKeyValues(body)
        params.driver = "mysql"
        return params
    end

    if scheme == "pgsql" or scheme == "postgres" or scheme == "postgresql" then
        local params = parseKeyValues(body)
        params.driver = "pgsql"
        return params
    end

    error("[VdoDsn] Unsupported driver scheme: " .. scheme)
end

return dsn
