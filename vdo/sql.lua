-- splits a sql statement into literal chunks and an ordered placeholder list, recognizing both positional (?) and named (:name) markers while ignoring anything inside string literals, line comments, or postgres :: casts, with the result driving native-placeholder binding or emulated literal substitution depending on the driver
local sql = {}

-- parse returns { chunks, order } where the original sql equals chunks interleaved with placeholders (chunks[1] .. ph(1) .. chunks[2] .. ph(2) .. ...) so #chunks always equals #order + 1, and order[i] is a 1-based number for a positional marker or the name string for a named marker
function sql.parse(statement)
    local chunks = {}
    local order = {}

    local current = {}
    local i = 1
    local length = #statement
    local positional = 0

    local function flushChunk()
        chunks[#chunks + 1] = table.concat(current)
        current = {}
    end

    while i <= length do
        local c = statement:sub(i, i)

        if c == "'" or c == '"' or c == "`" then
            -- copy a quoted literal or backtick identifier verbatim, treating a doubled quote as an escaped quote
            local quote = c
            current[#current + 1] = c
            i = i + 1
            while i <= length do
                local d = statement:sub(i, i)
                current[#current + 1] = d
                i = i + 1
                if d == quote then
                    if statement:sub(i, i) == quote then
                        current[#current + 1] = quote
                        i = i + 1
                    else
                        break
                    end
                end
            end
        elseif c == "-" and statement:sub(i + 1, i + 1) == "-" then
            -- copy a line comment up to and including the newline
            local stop = statement:find("\n", i, true) or (length + 1)
            current[#current + 1] = statement:sub(i, stop - 1)
            i = stop
        elseif c == "/" and statement:sub(i + 1, i + 1) == "*" then
            -- copy a block comment verbatim so a marker inside it is never treated as a placeholder
            local stop = statement:find("*/", i + 2, true)
            if stop then
                current[#current + 1] = statement:sub(i, stop + 1)
                i = stop + 2
            else
                current[#current + 1] = statement:sub(i)
                i = length + 1
            end
        elseif c == ":" and statement:sub(i + 1, i + 1) == ":" then
            -- preserve a postgres cast operator so it is never mistaken for a named marker
            current[#current + 1] = "::"
            i = i + 2
        elseif c == "?" then
            positional = positional + 1
            order[#order + 1] = positional
            flushChunk()
            i = i + 1
        elseif c == ":" and statement:sub(i + 1, i + 1):match("[%a_]") then
            local name = statement:match("^:([%w_]+)", i)
            order[#order + 1] = name
            flushChunk()
            i = i + #name + 1
        else
            current[#current + 1] = c
            i = i + 1
        end
    end

    flushChunk()
    return { chunks = chunks, order = order }
end

-- resolves the bound value for placeholder slot index against the params table, accepting both a positional array and a named map under the same call
function sql.valueFor(parsed, params, index)
    local key = parsed.order[index]
    if params == nil then
        error("[VdoSql] Missing parameters for placeholder " .. tostring(key) .. ".")
    end
    return params[key]
end

-- rebuilds the statement using a driver-native placeholder, e.g. "?" for sqlite or "$n" for postgres
function sql.build(parsed, makePlaceholder)
    local out = { parsed.chunks[1] }
    for index = 1, #parsed.order do
        out[#out + 1] = makePlaceholder(index)
        out[#out + 1] = parsed.chunks[index + 1]
    end
    return table.concat(out)
end

return sql
