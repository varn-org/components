# 🌱 env

Loads a `.env` file and reads typed environment variables, with the real process environment always winning over file values. Missing files are not an error, and required-but-unset variables fail fast so configuration problems surface at startup instead of deep in a request.

```lua
local env = require("env")

env.load(".env")

local name = env.get("APP_NAME", "varn")
local port = env.int("APP_PORT", 8080)
local debug = env.bool("APP_DEBUG", false)
local token = env.require("API_TOKEN")
```

Synchronous and pure Lua — no async coroutine or native backend required. Because the runtime has no `os.setenv`, loaded values are kept in an in-memory store and consulted only after `os.getenv`, so an actual environment variable is never shadowed by a file entry.

## Loading

| Function | What it does |
|---|---|
| `env.load(path)` | Read `KEY=VALUE` pairs from the file at `path` (default `.env`), skipping blank lines, `#` comments, and malformed lines, and stripping one layer of matching quotes plus surrounding whitespace from each value. A leading `export ` is accepted. Names already defined in the real environment are not overridden. A missing file loads nothing. Returns a table of the names actually stored. |

## Reading

| Function | What it does |
|---|---|
| `env.get(name, default)` | The value of `name`, or `default` when it is unset. |
| `env.require(name)` | The value of `name`, raising when it is unset. |
| `env.int(name, default)` | `name` parsed as an integer, falling back to `default` when unset and raising when the value is present but not an integer. |
| `env.bool(name, default)` | `name` parsed as a boolean, falling back to `default` when unset and raising on a value that is neither truthy nor falsy. `1`, `true`, `yes`, `on` are true; `0`, `false`, `no`, `off`, and empty are false. |

Every reader consults the real environment first and the loaded file second, so `os.getenv` values remain authoritative.

## Reference, examples, and tests

- Full reference: [docs/components/env.md](../docs/env.md)
- Runnable example: [examples/](examples/) — writes a throwaway `.env`, loads it, and reads typed values out of it.
- Test: [tests/](tests/) covers file parsing, quote and whitespace handling, typed accessors, required and missing handling, bad-value errors, and that a real environment value is never shadowed by the file. Run it directly with `./build/bin/varn components/env/tests/integration.lua`.
