# 🧪 validate

Declarative table validation. Describe the expected shape with a schema of field rules, then check a Lua table against it and get back every problem at once, keyed by the field path that failed.

```lua
local validate = require("validate")

local schema = {
    name = validate.string{ min = 1, max = 50 },
    age = validate.number{ min = 0, max = 130 },
    role = validate.string{ enum = { "admin", "user" }, default = "user" },
}

local ok, errors = validate.check(schema, { name = "Alice", age = 30 })
-- ok is true; role defaults to "user"
```

`check` reports all failures instead of stopping at the first, so `errors` maps each failing path (dotted for nested tables, `field[i]` for array elements) to its message. Pure Lua with no external dependencies, so it runs on every target.

## Rules

| Function | What it does |
|---|---|
| `validate.string(opts)` | A string field. |
| `validate.number(opts)` | A numeric field. |
| `validate.integer(opts)` | A number that must also have no fractional part. |
| `validate.boolean(opts)` | A boolean field. |
| `validate.table(schema, opts)` | A nested object whose `schema` maps field names to rules, validated recursively. |
| `validate.array(elementRule, opts)` | A list whose every element must satisfy `elementRule`. |

## Options

`opts` is shared by every rule and carries the constraints for that field.

| Option | What it does |
|---|---|
| `required` | Whether the field must be present; defaults to `true`, set `false` to make it optional. |
| `min` / `max` | Bounds on string length, array length, or a numeric value; ignored for tables and booleans. |
| `pattern` | A Lua pattern the string must match; applies to strings only. |
| `enum` | The set of allowed values the field must be one of. |
| `default` | A value substituted when the field is missing, which also satisfies `required`. |

## Checking

| Function | What it does |
|---|---|
| `validate.check(schema, data)` | Validate `data` against `schema`; return `true` on success, or `false` plus a table mapping each failing field path to its message. A non-table `data` fails with an `_` error. |

## Reference, examples, and tests

- Full reference: [docs/components/validate.md](../docs/validate.md)
- Runnable example: [examples/](examples/) — a user payload validated against strings, numbers, an enum, a pattern, an array, and a nested table.
- Test: [tests/integration.lua](tests/integration.lua) covers required and optional fields, types, min/max on values and lengths, pattern, enum, defaults, nested tables, and arrays. Run it directly with `./build/bin/varn components/validate/tests/integration.lua`.
