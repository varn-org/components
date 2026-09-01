<p align="center">
    <a href="https://github.com/varn-org/components" target="_blank" rel="noopener noreferrer">
        <img width="200" src="https://raw.githubusercontent.com/varn-org/varn/main/extras/images/logo.png" alt="Varn Logo">
    </a>
</p>

<h1 align="center">Varn Components</h1>

<p align="center">
    <a href="https://github.com/varn-org/components/actions/workflows/tests.yml"><img src="https://github.com/varn-org/components/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
</p>

The component library for [Varn](https://github.com/varn-org/varn) — batteries written in pure Lua on top of the native modules the engine already ships. Databases, caches, job queues, AI providers, validation and testing, each one a directory you drop in and `require`.

They live apart from the engine on purpose. A component is Lua, so it needs a `varn` binary and nothing else: no C++ toolchain, no build, and no engine release to ship a fix.

## 🚀 Quickstart

```bash
git clone https://github.com/varn-org/components varn-components
```

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"

local async = require("async")
local redis = require("redis")

async.run(function()
    local client = redis.connect({ host = "127.0.0.1" })
    client:set("greeting", "hello from varn")
    print(client:get("greeting"))
    client:close()
end)
```

Every component runs on the event loop, so socket, HTTP and database work belongs inside an async coroutine (`async.run` / `async.spawn`).

## 🧱 The components

| Component | What you get |
|----------------|--------------|
| 🗄️ [`vdo`](docs/vdo.md) | PDO-style database access for SQLite, MySQL/MariaDB, and PostgreSQL through their own client libraries |
| 🔴 [`redis`](docs/redis.md) | Redis client with full command coverage and pipelining |
| 🏊 [`pool`](docs/pool.md) | Generic async connection pool with acquire, release, and `with` |
| ⏰ [`scheduler`](docs/scheduler.md) | Durable job queue with cron-like scheduling backed by a database |
| 🤖 [`ai`](docs/ai.md) | One client for OpenAI, Anthropic, Gemini, and ElevenLabs (chat, embeddings, audio, images) |
| 🔧 [`env`](docs/env.md) | Load `.env` files and read typed environment variables |
| ✅ [`validate`](docs/validate.md) | Validate tables against a schema with clear error messages |
| 🧪 [`test`](docs/test.md) | A tiny test runner with `describe`/`it` and expectations |
| 🔁 [`retry`](docs/retry.md) | Retry with backoff and simple interval scheduling |

Each component keeps its own `README.md`, `examples/` and `tests/` beside its code, and the full reference for each lives under [docs/](docs/).

## 🔗 What a component needs from the engine

Components call the native modules by name, so a `varn` binary that carries them is the only requirement:

| Component | Uses |
|---|---|
| `ai` | `async` `crypto` `fs` `http` `json` |
| `redis` | `async` `socket` |
| `scheduler` | `async` `crypto` `json` |
| `vdo` | `ffi` `platform` |
| `pool` | `async` |
| `retry` | `async` `log` |
| `env` `test` `validate` | nothing — pure Lua |

They are **native-only**: the browser build has no server sockets or FFI, so a component that reaches the network or loads a client library does not run there.

A component that needs a minimum engine version can read it without parsing anything:

```lua
local v = require("platform").version   -- { major, minor, patch, string }
if v.major < 1 then
    error("this component needs varn 1.0 or newer")
end
```

## 🧪 Tests

`run.py` fetches a released `varn` binary and runs the suite against it, so testing needs no engine checkout and no compiler.

```bash
python3 run.py                          # the tests that need only the binary
python3 run.py --backends               # plus redis, mysql and postgres through docker
python3 run.py --varn-version latest    # against the newest release instead of the pinned one
python3 run.py --ai-live                # plus the real-api ai smoke, per provider key
python3 run.py --down                   # stop the docker backends
```

The downloaded binary is cached under `.varn/<version>/`. CI runs the first form on Linux, macOS and Windows, the second on Linux, and repeats weekly so a new engine release that breaks a component is caught even when nothing here changed.

## 📚 Documentation

| | |
|---|---|
| 🧱 Component reference | [docs/](docs/) |
| 🌐 Engine and Lua API | [varn-org/varn](https://github.com/varn-org/varn) |
| 🧩 Playground | [varn.pages.dev](https://varn.pages.dev) |

## 💜 Support

[GitHub Sponsors](https://github.com/sponsors/paulocoutinhox) · [Ko-fi](https://ko-fi.com/paulocoutinho).

Made with care by [Paulo Coutinho](https://github.com/paulocoutinhox).
