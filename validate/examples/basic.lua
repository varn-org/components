-- validates a user payload against a schema with strings, numbers, an enum, a pattern, an array and a nested table then prints the errors a bad payload produces
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local validate = require("validate")

local userSchema = {
    name = validate.string{ min = 1, max = 50 },
    age = validate.number{ min = 0, max = 130 },
    email = validate.string{ pattern = "^[%w._%%+-]+@[%w.-]+%.%a+$" },
    role = validate.string{ enum = { "admin", "user", "guest" }, default = "user" },
    tags = validate.array(validate.string{ min = 1 }, { required = false }),
    address = validate.table({
        city = validate.string{ min = 1 },
        zip = validate.string{ pattern = "^%d+$" },
    }, { required = false }),
}

local good = {
    name = "Alice",
    age = 30,
    email = "alice@example.com",
    tags = { "lua", "varn" },
    address = { city = "Lisbon", zip = "1000" },
}

local ok, errors = validate.check(userSchema, good)
print("good payload ok:", ok)

local bad = {
    name = "",
    age = 200,
    email = "not-an-email",
    role = "superuser",
    tags = { "ok", "" },
    address = { city = "Porto", zip = "abc" },
}

ok, errors = validate.check(userSchema, bad)
print("bad payload ok:", ok)
local fields = {}
for field in pairs(errors) do
    fields[#fields + 1] = field
end
table.sort(fields)
for _, field in ipairs(fields) do
    print("  " .. field .. ": " .. errors[field])
end

print("validate basic ok")
