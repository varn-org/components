# 🤖 ai

Unified client for large language models and audio, over the native http client. Text, images, and audio across OpenAI, Anthropic Claude, Google Gemini, and every OpenAI-compatible provider, with streaming, tools, and vision.

```lua
local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({ provider = "openai", model = "gpt-4o-mini" })
    local res = client:generate({ messages = { { role = "user", content = "hello" } } })
    print(res.text)
end)
```

Every call yields on the event loop, so the whole lifecycle must run inside an async coroutine (`async.run` / `async.spawn`). Native-only — the component relies on the http client and is not available in the browser (wasm).

## Text and vision

| Function | What it does |
|---|---|
| `ai.client(config)` | Build a client; `config` takes `provider`, `model`, optional `apiKey` (else read from the provider env var), `baseUrl`, `headers`, `imageModel`, `embedModel`, `timeoutSeconds`. |
| `client:generate(request)` | One-shot completion, returns `{ text, finishReason, toolCalls, reasoning, usage, raw }`. |
| `client:stream(request, onEvent)` | Streaming completion; `onEvent` receives `{ type = "text"/"reasoning"/"done", delta, ... }` and runs synchronously so it must not yield. Returns the same accumulated result as `generate`. |
| `client:image(request)` | Image generation, returns `{ images = { ... }, raw }`; each image is `{ base64, url, revisedPrompt }` on OpenAI and `{ base64, mediaType }` on Gemini. |
| `client:embed(request)` | Embeddings, returns `{ embeddings = { vector }, usage, raw }`; implemented over the OpenAI wire only, so a provider without an embeddings endpoint raises. |

A `request` is normalized across providers: `messages` (each `{ role, content }` where `content` is a string or a list of `{ type = "text"/"image", text/url/base64 }` parts), plus optional `system`, `model`, `temperature`, `maxTokens`, `topP`, `stop`, `tools`, `toolChoice`, `responseFormat`, `reasoningEffort`, and `extra` for raw passthrough. A `tool` is `{ name, description, parameters }`; a tool result is a message `{ role = "tool", toolCallId, name, content }`.

## Audio (ElevenLabs)

| Function | What it does |
|---|---|
| `ai.audio(config)` | Build an audio client; `config` takes optional `apiKey` (else `ELEVENLABS_API_KEY`), `baseUrl`, `timeoutSeconds`. |
| `client:tts(request)` | Text to speech, returns `{ audio, contentType }` with raw audio bytes. |
| `client:ttsStream(request, onChunk)` | Streaming text to speech; `onChunk` receives raw audio bytes as they arrive. |
| `client:stt(request)` | Speech to text from `request.audio` bytes, returns the transcript table. |
| `client:voices()` | List the account voices. |
| `client:soundEffect(request)` | Generate a sound effect from a text prompt, returns `{ audio, contentType }`. |

## Helpers

| Function | What it does |
|---|---|
| `ai.saveImage(image, path)` | Write an `image()` result to a file, decoding its base64 or downloading its url. |
| `ai.saveAudio(bytes, path)` | Write raw audio bytes from `tts()` or `soundEffect()` to a file. |

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
| `elevenlabs` | ElevenLabs (via `ai.audio`) | — | yes | `ELEVENLABS_API_KEY` |

Any OpenAI-compatible endpoint works by setting `baseUrl` and `model` on an existing provider. Models are passed per request or per client; this component does not pin model ids, which change over time.

## Reference, examples, and tests

- Full reference: [docs/components/ai.md](../docs/ai.md)
- Runnable examples: [examples/](examples/) — text, stream, tools, vision, structured, image, audio. Each reads its key from the provider env var.
- Tests: [tests/mock_test.lua](tests/mock_test.lua) and [tests/adapters_test.lua](tests/adapters_test.lua) run against an in-process mock server with no network or keys, and both are part of `python3 varn.py test`. [tests/live_test.lua](tests/live_test.lua) hits the real APIs and is opt-in through `python3 varn.py test-db --ai-live`, skipping each provider whose `*_API_KEY` is absent.
