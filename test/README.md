# ✅ test

Minimal jest-style test runner. Group cases with `describe`, register them with `it`, assert with a fluent `expect`, and let `run` print a pass/fail summary and exit non-zero when anything fails.

```lua
local test = require("test")
local describe, it, expect = test.describe, test.it, test.expect

describe("math", function()
    it("adds two numbers", function()
        expect(2 + 3):toBe(5)
    end)
end)

test.run()
```

Cases are collected in declaration order and only run when `test.run()` is called. Pure Lua with no external dependencies, so it runs on every target.

## Structure

| Function | What it does |
|---|---|
| `test.describe(name, fn)` | Group every case registered inside `fn` under `name`; groups can nest. |
| `test.it(name, fn)` | Register one case that runs later when the suite runs. |
| `test.expect(value)` | Return a matcher object bound to `value`. |
| `test.run()` | Run every registered case, print a per-case line and a summary, exit non-zero if any failed; idempotent, so a second call is a no-op. |

## Matchers

| Matcher | What it does |
|---|---|
| `expect(value):toBe(expected)` | Pass on exact identity or primitive equality (`==`). |
| `expect(value):toEqual(expected)` | Pass when the values are deeply equal by content, recursing into tables. |
| `expect(value):toBeTruthy()` | Pass when the value is anything but `nil` or `false`. |
| `expect(value):toBeFalsy()` | Pass when the value is `nil` or `false`. |
| `expect(fn):toThrow()` | Require a function and pass when calling it raises. |

A failing matcher raises with a message describing the expected and actual value, so the case is reported as a failure with that message.

## Reference, examples, and tests

- Full reference: [docs/components/test.md](../docs/test.md)
- Runnable example: [examples/](examples/) — a small suite showing `describe`/`it`/`expect` and the printed summary.
- Test: [tests/integration.lua](tests/integration.lua) exercises every matcher and verifies each one fails on wrong input. Run it directly with `./build/bin/varn components/test/tests/integration.lua`.
