-- loads a .env file and reads typed environment variables, with the real environment always winning since the runtime has no os.setenv to push values back
local env = {}

-- names parsed out of a loaded .env file, consulted only after os.getenv so the real environment stays authoritative
local loaded = {}

-- strips surrounding whitespace from both ends of a string
local function trim(value)
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

-- removes one layer of matching single or double quotes from an already-trimmed value, leaving an unquoted value untouched
local function unquote(value)
    local quote = value:sub(1, 1)
    if (quote == '"' or quote == "'") and value:sub(-1) == quote and #value >= 2 then
        return value:sub(2, -2)
    end
    return value
end

-- parses one "KEY=VALUE" line into a key/value pair, returning nil for blanks and comments, and allowing a leading "export " for files copied from shell scripts
local function parseLine(line)
    local stripped = trim(line)
    if stripped == "" or stripped:sub(1, 1) == "#" then
        return nil
    end

    stripped = stripped:gsub("^export%s+", "")

    local key, value = stripped:match("^([%w_.]+)%s*=%s*(.*)$")
    if not key then
        return nil
    end

    return key, unquote(trim(value))
end

-- reads name from the real environment first, then from a loaded file, so an actual environment value is never shadowed by the file
local function lookup(name)
    local value = os.getenv(name)
    if value ~= nil then
        return value
    end
    return loaded[name]
end

-- loads KEY=VALUE pairs from a .env file into the in-memory store without overriding names the real environment defines, treating a missing file as no error and returning the table of stored names
function env.load(path)
    path = path or ".env"

    local file = io.open(path, "r")
    if not file then
        return {}
    end

    local applied = {}
    for line in file:lines() do
        local key, value = parseLine(line)
        if key and os.getenv(key) == nil then
            loaded[key] = value
            applied[key] = value
        end
    end
    file:close()

    return applied
end

-- returns the value of name, or default when it is unset
function env.get(name, default)
    local value = lookup(name)
    if value == nil then
        return default
    end
    return value
end

-- returns the value of name, raising when it is unset so a missing required setting fails fast at startup
function env.require(name)
    local value = lookup(name)
    if value == nil then
        error("[Env] Missing required variable: " .. tostring(name), 2)
    end
    return value
end

-- returns name parsed as an integer, falling back to default when unset and raising when the value is present but not an integer
function env.int(name, default)
    local value = lookup(name)
    if value == nil then
        return default
    end
    local number = math.tointeger(tonumber(value))
    if number == nil then
        error("[Env] Variable " .. name .. " is not an integer: " .. tostring(value), 2)
    end
    return number
end

-- common spellings for a truthy environment flag, with everything else reading as false
local TRUE = { ["1"] = true, ["true"] = true, ["yes"] = true, ["on"] = true }
local FALSE = { ["0"] = true, ["false"] = true, ["no"] = true, ["off"] = true, [""] = true }

-- returns name parsed as a boolean, falling back to default when unset and raising on a value that is neither truthy nor falsy
function env.bool(name, default)
    local value = lookup(name)
    if value == nil then
        return default
    end
    local lowered = value:lower()
    if TRUE[lowered] then
        return true
    end
    if FALSE[lowered] then
        return false
    end
    error("[Env] Variable " .. name .. " is not a boolean: " .. tostring(value), 2)
end

return env
