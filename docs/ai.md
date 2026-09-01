# 🤖 ai

One client for large language models and audio, written in Lua on top of the native HTTP client.
Text, images, and audio across OpenAI, Anthropic Claude, Google Gemini, ElevenLabs, and every
OpenAI-compatible provider, with streaming, tool calling, and vision.

Point `package.path` at your clone of this repository first (see the [readme](../README.md)):

```lua
package.path = package.path .. ";varn-components/?.lua;varn-components/?/init.lua"
local ai = require("ai")
```

Every call yields on the event loop, so the whole lifecycle must run inside an async coroutine
(`async.run` / `async.spawn`). It is native-only, since it relies on the HTTP client's streaming path,
which is unavailable in the browser.

```lua
local async = require("async")

async.run(function()
    local client = ai.client({ provider = "openai", model = "gpt-4o-mini" })
    local res = client:generate({ messages = { { role = "user", content = "hello" } } })
    print(res.text)
end)
```

## Providers

| Provider | Wire | Image | Audio | Env var |
|---|---|---|---|---|
| `openai` | OpenAI Chat | yes | — | `OPENAI_API_KEY` |
| `anthropic` / `claude` | Messages | — | — | `ANTHROPIC_API_KEY` |
| `gemini` / `google` | generateContent | yes (native) | — | `GEMINI_API_KEY` |
| `grok` | OpenAI Chat | — | — | `XAI_API_KEY` |
| `deepseek` | OpenAI Chat | — | — | `DEEPSEEK_API_KEY` |
| `moonshot` / `kimi` | OpenAI Chat | — | — | `MOONSHOT_API_KEY` |
| `groq` | OpenAI Chat | — | — | `GROQ_API_KEY` |
| `mistral` | OpenAI Chat | — | — | `MISTRAL_API_KEY` |
| `together` | OpenAI Chat | — | — | `TOGETHER_API_KEY` |
| `openrouter` | OpenAI Chat | — | — | `OPENROUTER_API_KEY` |
| `ollama` | OpenAI Chat | — | — | none (local) |
| `elevenlabs` | ElevenLabs (through `ai.audio`) | — | yes | `ELEVENLABS_API_KEY` |

Any OpenAI-compatible endpoint works by setting `baseUrl` and `model` on an existing provider. Model
ids are passed per client or per request and are never pinned by this component, since they change
over time.

## Text and vision

`ai.client(config)` → a client.

| Option | Meaning |
|--------|---------|
| `provider` | one of the providers above |
| `model` | default model for `generate` and `stream` |
| `apiKey` | the key, or omitted to read the provider's env var |
| `baseUrl` | override the provider endpoint |
| `headers` | extra headers merged into every request |
| `imageModel` | default model for `image` |
| `embedModel` | default model for `embed` |
| `timeoutSeconds` | per-request timeout |

| Function | What it does |
|---|---|
| `client:generate(request)` | One-shot completion, returning `{ text, finishReason, toolCalls, reasoning, usage, raw }`. |
| `client:stream(request, onEvent)` | Streaming completion; `onEvent` receives `{ type = "text"/"reasoning"/"done", delta, ... }` and runs synchronously, so it must not yield. Returns the same accumulated result as `generate`. |
| `client:image(request)` | Image generation, returning `{ images = { ... }, raw }`; each image is `{ base64, url, revisedPrompt }` on OpenAI and `{ base64, mediaType }` on Gemini. |
| `client:embed(request)` | Embeddings, returning `{ embeddings = { vector }, usage, raw }`; implemented over the OpenAI wire only, so a provider without an embeddings endpoint raises. |

### The normalized request

A `request` is the same shape for every provider, and each adapter translates it to the wire:

- `messages` — a list of `{ role, content }`. `content` is a string, or a list of parts
  `{ type = "text", text = ... }` / `{ type = "image", url = ... }` / `{ type = "image", base64 = ... }`.
- `system` — a system instruction.
- `model`, `temperature`, `maxTokens`, `topP`, `stop` — the usual sampling controls.
- `tools` — a list of `{ name, description, parameters }` (JSON Schema), plus `toolChoice`.
- `responseFormat` — structured output, in the OpenAI `json_schema` shape.
- `reasoningEffort` — the provider's reasoning surface where it has one.
- `extra` — merged into the wire body verbatim, for anything a provider exposes that the normalized
  request does not.

A tool result is fed back as a message `{ role = "tool", toolCallId, name, content }`. The response
always carries `raw`, the untouched provider payload, so nothing is hidden.

## Audio

`ai.audio(config)` → an audio client. `config` takes `apiKey` (else `ELEVENLABS_API_KEY`), `baseUrl`,
and `timeoutSeconds`.

| Function | What it does |
|---|---|
| `client:tts(request)` | Text to speech, returning `{ audio, contentType }` with raw audio bytes. |
| `client:ttsStream(request, onChunk)` | Streaming text to speech; `onChunk` receives raw audio bytes as they arrive. |
| `client:stt(request)` | Speech to text from `request.audio` bytes, returning the transcript table. |
| `client:voices()` | List the account voices. |
| `client:soundEffect(request)` | Generate a sound effect from a text prompt, returning `{ audio, contentType }`. |

## Helpers

| Function | What it does |
|---|---|
| `ai.saveImage(image, path)` | Write an `image()` result to a file, decoding its base64 or downloading its url. |
| `ai.saveAudio(bytes, path)` | Write raw audio bytes from `tts()` or `soundEffect()` to a file. |

## Keys

A key is taken from `config.apiKey` when given, otherwise from the provider's environment variable.
It is never logged and never written to disk. Pair this with the [env](env.md) component to load keys
from a `.env` file.

## Examples

### `text.lua`

```lua
-- one-shot text generation, provider chosen by AI_PROVIDER (default openai) with the key read from the matching environment variable
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local response = client:generate({
        system = "you answer in a single short sentence",
        messages = { { role = "user", content = "name the three primary colors" } },
        temperature = 0.2,
        maxTokens = 64,
    })

    print(response.text)
    print("finish:", response.finishReason)
    if response.usage then
        print("tokens:", response.usage.totalTokens)
    end
end)
```

### `stream.lua`

```lua
-- streaming generation printing tokens as they arrive through the onEvent callback
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local result = client:stream({
        messages = { { role = "user", content = "write one short sentence about the ocean" } },
        maxTokens = 64,
    }, function(event)
        if event.type == "text" then
            io.write(event.delta)
            io.flush()
        end
    end)

    print()
    print("finish:", result.finishReason)
end)
```

### `tools.lua`

```lua
-- full tool-calling round trip where the model requests a tool, the program runs it, and the result is fed back for a final answer
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local weatherTool = {
    name = "get_weather",
    description = "get the current temperature for a city",
    parameters = {
        type = "object",
        properties = { city = { type = "string" } },
        required = { "city" },
    },
}

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local messages = { { role = "user", content = "what is the weather in Paris?" } }

    local first = client:generate({ messages = messages, tools = { weatherTool }, maxTokens = 256 })
    local call = first.toolCalls and first.toolCalls[1]
    assert(call, "the model did not call the tool")
    print("model called:", call.name, call.arguments)

    -- record the assistant turn that issued the call, then answer it
    messages[#messages + 1] = { role = "assistant", content = first.text, toolCalls = first.toolCalls }
    local args = json.decode(call.arguments)
    local reading = string.format("%d degrees celsius", 21)
    messages[#messages + 1] = { role = "tool", toolCallId = call.id, name = call.name, content = reading }
    print("tool result for", args.city, "->", reading)

    local final = client:generate({ messages = messages, tools = { weatherTool }, maxTokens = 256 })
    print("answer:", final.text)
end)
```

### `vision.lua`

```lua
-- multimodal input reading a local image, embedding it as a base64 data url, and asking the model about it
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local fs = require("fs")
local crypto = require("crypto")
local ai = require("ai")

local imagePath = os.getenv("AI_IMAGE_PATH") or "image.png"

async.run(function()
    local bytes = fs.readFile(imagePath):await()
    local mediaType = imagePath:match("%.jpe?g$") and "image/jpeg" or "image/png"
    local dataUrl = string.format("data:%s;base64,%s", mediaType, crypto.base64Encode(bytes))

    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local response = client:generate({
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = "describe this image in one sentence" },
                    { type = "image", url = dataUrl },
                },
            },
        },
        maxTokens = 128,
    })

    print(response.text)
end)
```

### `structured.lua`

```lua
-- structured output asking for json conforming to a schema and decoding the response with the openai-style response_format
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        model = os.getenv("AI_MODEL") or "gpt-4o-mini",
    })

    local response = client:generate({
        messages = { { role = "user", content = "give two facts about the moon" } },
        responseFormat = {
            type = "json_schema",
            json_schema = {
                name = "facts",
                strict = true,
                schema = {
                    type = "object",
                    properties = { facts = { type = "array", items = { type = "string" } } },
                    required = { "facts" },
                    additionalProperties = false,
                },
            },
        },
        maxTokens = 256,
    })

    local decoded = json.decode(response.text)
    for index, fact in ipairs(decoded.facts) do
        print(index, fact)
    end
end)
```

### `image.lua`

```lua
-- image generation, saving the result to a file with ai.saveImage
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        imageModel = os.getenv("AI_IMAGE_MODEL") or "gpt-image-1",
    })

    local result = client:image({
        prompt = "a calm watercolor landscape of green hills at sunrise",
        size = "1024x1024",
    })

    local path = os.getenv("AI_IMAGE_OUT") or "image.png"
    ai.saveImage(result.images[1], path)
    print("saved", path)
end)
```

### `audio.lua`

```lua
-- text to speech with elevenlabs, saving the audio and transcribing it back with speech to text
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local audio = ai.audio({ provider = "elevenlabs" })

    local voices = audio:voices()
    local voiceId = voices[1] and voices[1].voice_id

    local speech = audio:tts({
        text = "Hello from Varn. This sentence was spoken by a machine.",
        voiceId = voiceId,
        model = "eleven_multilingual_v2",
    })

    local path = os.getenv("AI_AUDIO_OUT") or "speech.mp3"
    ai.saveAudio(speech.audio, path)
    print("saved", path, "(" .. #speech.audio .. " bytes)")

    local transcript = audio:stt({ audio = speech.audio, model = "scribe_v2" })
    print("transcript:", transcript.text)
end)
```
