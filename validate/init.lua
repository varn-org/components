-- validate checks a Lua table against a declarative schema and returns ok plus a flat table of field errors.
-- each schema field is a rule built by validate.string, validate.number and similar constructors.
-- validate.check walks the schema and reports every problem at once instead of failing on the first.
local validate = {}

-- builds a rule descriptor for one field where kind drives which checks apply.
-- opts carries required, min, max, pattern, enum and default plus the nested schema or element rule for tables and arrays.
local function rule(kind, opts, extra)
    opts = opts or {}
    local descriptor = {
        kind = kind,
        required = opts.required ~= false,
        min = opts.min,
        max = opts.max,
        pattern = opts.pattern,
        enum = opts.enum,
        default = opts.default,
    }
    if extra then
        for key, value in pairs(extra) do
            descriptor[key] = value
        end
    end
    return descriptor
end

-- a field is required by default unless opts sets required to false
function validate.string(opts)
    return rule("string", opts)
end

function validate.number(opts)
    return rule("number", opts)
end

-- an integer is a number that must also have no fractional part
function validate.integer(opts)
    return rule("integer", opts)
end

function validate.boolean(opts)
    return rule("boolean", opts)
end

-- a nested object whose schema is a table of field-name to rule validated recursively
function validate.table(schema, opts)
    return rule("table", opts, { schema = schema })
end

-- a list whose every element must satisfy elementRule with min and max constraining the element count
function validate.array(elementRule, opts)
    return rule("array", opts, { element = elementRule })
end

-- records a field message into errors keyed by its path
local function fail(errors, path, message)
    errors[path] = message
end

-- the measure used for min and max is the character count of a string, the element count of an array, or the value itself for other kinds
local function lengthOf(kind, value)
    if kind == "string" then
        return #value
    end
    if kind == "array" then
        return #value
    end
    return value
end

-- validates one value against one rule and writes any problems into errors under path.
-- returns the value to store where a default substitutes a missing optional field.
local function checkValue(descriptor, value, path, errors)
    if value == nil then
        if descriptor.default ~= nil then
            return descriptor.default
        end
        if descriptor.required then
            fail(errors, path, "is required")
        end
        return nil
    end

    local kind = descriptor.kind
    local luaType = type(value)

    if kind == "string" or kind == "boolean" then
        if luaType ~= kind then
            fail(errors, path, "must be a " .. kind)
            return value
        end
    elseif kind == "number" or kind == "integer" then
        if luaType ~= "number" then
            fail(errors, path, "must be a number")
            return value
        end
        if kind == "integer" and math.tointeger(value) == nil then
            fail(errors, path, "must be an integer")
            return value
        end
    elseif kind == "table" or kind == "array" then
        if luaType ~= "table" then
            fail(errors, path, "must be a " .. (kind == "array" and "array" or "table"))
            return value
        end
    end

    -- enum membership
    if descriptor.enum then
        local allowed = false
        for _, option in ipairs(descriptor.enum) do
            if value == option then
                allowed = true
                break
            end
        end
        if not allowed then
            fail(errors, path, "must be one of the allowed values")
        end
    end

    -- min and max compare a length for strings and arrays and the value itself for numbers, and do not apply to tables or booleans
    if (descriptor.min ~= nil or descriptor.max ~= nil) and (kind == "string" or kind == "array" or kind == "number" or kind == "integer") then
        local measure = lengthOf(kind, value)
        if descriptor.min ~= nil and measure < descriptor.min then
            fail(errors, path, "must be at least " .. tostring(descriptor.min))
        end
        if descriptor.max ~= nil and measure > descriptor.max then
            fail(errors, path, "must be at most " .. tostring(descriptor.max))
        end
    end

    -- pattern only applies to strings
    if descriptor.pattern and kind == "string" and not value:match(descriptor.pattern) then
        fail(errors, path, "has an invalid format")
    end

    -- recurse into a nested object schema, storing back so nested defaults land in the data
    if kind == "table" and descriptor.schema then
        for field, fieldRule in pairs(descriptor.schema) do
            value[field] = checkValue(fieldRule, value[field], path .. "." .. field, errors)
        end
    end

    -- validate every array element against the element rule
    if kind == "array" and descriptor.element then
        for index, item in ipairs(value) do
            value[index] = checkValue(descriptor.element, item, path .. "[" .. index .. "]", errors)
        end
    end

    return value
end

-- validates data against schema which is a table of field-name to rule.
-- returns true on success or false plus a table mapping each failing field path to its message.
function validate.check(schema, data)
    if type(data) ~= "table" then
        return false, { ["_"] = "value must be a table" }
    end

    -- store each result back so a default substitutes the missing field in data, as documented
    local errors = {}
    for field, fieldRule in pairs(schema) do
        data[field] = checkValue(fieldRule, data[field], field, errors)
    end

    if next(errors) == nil then
        return true
    end
    return false, errors
end

return validate
