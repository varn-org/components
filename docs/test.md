# 🧪 Test
A tiny test runner: `describe` groups cases, `it` registers one, and `expect` builds fluent
assertions. The runner prints a pass/fail summary and exits non-zero when anything fails, so it
drops straight into a CI step.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local test = require("test")
```

## Writing tests

- `test.describe(name, fn)` → groups every `it` registered inside `fn` under `name`.
- `test.it(name, fn)` → registers one case. `fn` runs later, when the suite runs.
- `test.expect(value)` → a matcher object:

| Matcher | Passes when |
|---------|-------------|
| `:toBe(x)` | `value == x` (identity / primitive equality) |
| `:toEqual(t)` | `value` deeply equals `t` (tables compared by content) |
| `:toBeTruthy()` | `value` is anything but `nil` / `false` |
| `:toBeFalsy()` | `value` is `nil` or `false` |
| `:toThrow()` | `value` is a function and calling it raises |

- `test.run()` → runs every registered case, prints a line per case and a summary, and calls
  `os.exit(1)` if any failed. Call it once at the end of your suite.

```lua
local test = require("test")
local describe, it, expect = test.describe, test.it, test.expect

describe("math", function()
    it("adds", function()
        expect(2 + 3):toBe(5)
    end)

    it("compares tables", function()
        expect({ a = 1 }):toEqual({ a = 1 })
    end)

    it("detects a throw", function()
        expect(function() error("boom") end):toThrow()
    end)
end)

test.run()
```

Output:

```
  ok   - math > adds
  ok   - math > compares tables
  ok   - math > detects a throw

3 passed, 0 failed (3 total)
```

## Example

### `basic.lua`

A small suite covering each matcher, ending with `test.run()` to print the summary.

```lua
-- a small suite showing describe/it/expect and the pass/fail summary the runner prints
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local test = require("test")
local describe, it, expect = test.describe, test.it, test.expect

local function add(a, b)
    return a + b
end

describe("math", function()
    it("adds two numbers", function()
        expect(add(2, 3)):toBe(5)
    end)

    it("is commutative", function()
        expect(add(2, 3)):toBe(add(3, 2))
    end)
end)

describe("tables", function()
    it("compares by content", function()
        expect({ a = 1, b = { 2, 3 } }):toEqual({ a = 1, b = { 2, 3 } })
    end)
end)

describe("errors", function()
    it("detects a throw", function()
        expect(function()
            error("boom")
        end):toThrow()
    end)

    it("treats a value as truthy", function()
        expect("present"):toBeTruthy()
        expect(nil):toBeFalsy()
    end)
end)

test.run()
```
