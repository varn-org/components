# ✅ validate

Validate a Lua table against a declarative schema, getting back every problem at once instead of
failing on the first. Each schema field is a rule built by `validate.string{...}`,
`validate.number{...}`, and friends.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local validate = require("validate")
```

## Rules

| Builder | Validates |
|---------|-----------|
| `validate.string(opts)` | a string |
| `validate.number(opts)` | a number |
| `validate.integer(opts)` | a number with no fractional part |
| `validate.boolean(opts)` | a boolean |
| `validate.table(schema, opts)` | a nested object, recursing into `schema` |
| `validate.array(elementRule, opts)` | a list whose every element matches `elementRule` |

`opts` (all optional):

| Option | Meaning |
|--------|---------|
| `required` | field must be present; `true` by default, pass `required = false` to make it optional |
| `default` | substituted when the field is missing, which also satisfies `required` |
| `min` / `max` | bounds on a number's value, or on a string's length / an array's element count |
| `pattern` | a Lua pattern the string must match |
| `enum` | a list of allowed values |

## Checking

`validate.check(schema, data)` walks `schema` (a table of field name → rule) over `data`.

- On success → `true`.
- On failure → `false, errors`, where `errors` maps each failing field path to a message. Nested
  fields use a dotted path (`"address.city"`) and array elements use an index (`"tags[2]"`).

```lua
local userSchema = {
    name  = validate.string{ min = 1, max = 50 },
    age   = validate.number{ min = 0, max = 130 },
    email = validate.string{ pattern = "^[%w._%%+-]+@[%w.-]+%.%a+$" },
    role  = validate.string{ enum = { "admin", "user", "guest" }, default = "user" },
    tags  = validate.array(validate.string{ min = 1 }, { required = false }),
    address = validate.table({
        city = validate.string{ min = 1 },
        zip  = validate.string{ pattern = "^%d+$" },
    }, { required = false }),
}

local ok, errors = validate.check(userSchema, payload)
if not ok then
    for field, message in pairs(errors) do
        print(field .. ": " .. message)
    end
end
```

## Example

### `basic.lua`

Validates a good and a bad payload against the schema above and prints the errors the bad one
produces (an empty name, an out-of-range age, a malformed email, an unknown role, an empty tag, and
a non-numeric zip).
