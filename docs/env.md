# 🔧 env

Load a `.env` file and read typed environment variables. The real environment (`os.getenv`) always
wins; a loaded file only supplies names the environment does not already define.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local env = require("env")
```

## Loading

`env.load(path?)` reads `KEY=VALUE` lines from a file (default `".env"`) into an in-memory store.
Blank lines and `#` comments are ignored, surrounding whitespace is trimmed, one layer of matching
single or double quotes is stripped, and a leading `export ` is allowed. A name already present in
the real environment is never overwritten, and a missing file is not an error — it simply loads
nothing. Returns the table of names it stored.

```lua
env.load()              -- loads ./.env
env.load("config/.env") -- loads a specific file
```

```ini
# app.env
APP_NAME=varn-demo
APP_PORT=8080
APP_DEBUG="true"
export APP_REGION=eu-west-1
```

## Reading

Every accessor consults the real environment first, then the loaded file.

- `env.get(name, default?)` → the value, or `default` when unset.
- `env.require(name)` → the value, raising when unset so a missing required setting fails fast.
- `env.int(name, default?)` → the value parsed as an integer, or `default` when unset; raises when
  the value is present but not an integer.
- `env.bool(name, default?)` → the value parsed as a boolean, or `default` when unset. `1`, `true`,
  `yes`, and `on` are true; `0`, `false`, `no`, `off`, and `""` are false; anything else raises.

```lua
local name   = env.get("APP_NAME", "app")
local port   = env.int("APP_PORT", 8080)
local debug  = env.bool("APP_DEBUG", false)
local region = env.require("APP_REGION")
```

> The runtime has no `os.setenv`, so loaded values live in the component's own store rather than the
> process environment. Read them through `env.*`, not `os.getenv`.

## Example

### `basic.lua`

```lua
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local env = require("env")

env.load(dir .. "/app.env")

print("name:", env.get("APP_NAME"))
print("port:", env.int("APP_PORT"))
print("debug:", env.bool("APP_DEBUG", false))
print("region:", env.require("APP_REGION"))
```
