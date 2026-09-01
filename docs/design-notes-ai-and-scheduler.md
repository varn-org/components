# Mega plan — `ai` and `scheduler` components

Working checklist and research record for two additions to Varn:

1. `ai` — complete clients for text and image generation across OpenAI, Anthropic Claude, Google Gemini, xAI Grok, Moonshot/Kimi, DeepSeek, Mistral, Groq, Together, OpenRouter, and Ollama — non-streaming, streaming, tools/function calling, and each provider's native features.
2. `scheduler` — durable background-task scheduler (resilient like a real job queue, not FastAPI's in-process tasks): immediate / run-at-datetime / fixed-interval, with status, full history, add/remove/query, surviving restarts and resetting killed in-progress tasks back to the queue. **Store = the `vdo` component.**

Decisions locked: streaming is built now (the HTTP core gains a streaming path — no backward-compat with the old full-body-only design); the scheduler persists through `vdo`; provider APIs below were verified live on **2026-06-21**.

**Status (2026-06-22): all three parts shipped and validated.** Part 3 (HTTP client streaming + headers) is live and tested against the real OpenAI API. `components/ai/` ships the transport, the OpenAI/Anthropic/Gemini/ElevenLabs adapters, seven examples, a network-free mock test, and a README — validated live against OpenAI (text/stream/tools/embed/image), Anthropic (text/stream/tools), Gemini (text/stream/tools/native image), ElevenLabs (tts/stream/stt/voices), and Grok/DeepSeek/OpenRouter. `components/scheduler/` ships the vdo-backed store, the full state machine with boot-epoch crash recovery and backoff retries, three examples, a test, and a README. Both component tests run in `varn.py test` (51 passed). The checklists below are kept as the design record.

---

## Part 0 — Internal audit and the one core change (done)

### Available today
- **HTTP client** (`require("http").client`): `client.request/get/post(opts)` + raw `requestRaw`. Options `url/method/headers/body/query/json/timeoutSeconds/verifyTls/insecure/maxResponseBytes`. Resolves a promise to `{status, ok, headers, body, json()}`, blocking work on `ioPool`. [HttpClientModule.cpp](https://github.com/varn-org/varn/blob/main/modules/http/src/HttpClientModule.cpp).
- **json / crypto base64 / fs / async** (`sleep/spawn/run/promise/deferred` + combinators, backed by `EventLoop::postDelayed`) / **ffi**.
- **`vdo`** ([components/vdo](../../components/vdo)): PDO-style facade over sqlite/mysql/pgsql via ffi, DSN-selected. API: `vdo.connect(dsn,user,pass,opts)` → `db:exec(sql)`, `db:prepare(sql)` → `stmt:execute(params)/fetch()/fetchAll()/rowCount()/close()` (binding `?` or `:name`), `db:query(sql,params)`, `db:lastInsertId()`, `db:beginTransaction()/commit()/rollBack()/inTransaction()`, `db:transaction(fn)` (atomic block), `db:close()`.
- **Component pattern**: dir under `components/` with `init.lua` returning a table; long-lived socket work runs inside `async.spawn`/`async.run`.
- **Shared async dispatch**: `varn::async::runOnPool(L, rt, pool, tag, work)` ([AsyncTask.cpp](https://github.com/varn-org/varn/blob/main/modules/async/src/AsyncTask.cpp)).

### Gaps
- ❌ HTTP client returns the **full body only** (`VARN/1 <status> <len>\n<body>`); no per-chunk callback.
- ❌ Response **headers are dropped** (`headers` table always empty) — rate-limit/`retry-after`/request-id/SSE content-type invisible.
- ⚠️ No repeating-timer primitive, but `async.spawn` + a `async.sleep(ms):await()` loop gives a tick and keeps the process alive.

### Verdicts (architecture)
- **`ai` (text, image, audio, streaming, tools)** → Lua component on top of the project HTTP client, which gains a streaming path + response headers (Part 3). Streaming is HTTP — the response body just arrives in pieces — so the right home is the real HTTP client (Poco already does HTTP/1.1 + TLS + chunked decoding correctly), not a hand-rolled HTTP parser over a raw socket. The change also replaces the `VARN/1 <status> <len>\n<body>` wire-string with a proper resolved `{status, headers, body}` table. This benefits every component, not just `ai`.
- **`scheduler`** → pure component over `vdo` + `async` tick loop + boot-epoch recovery + named handlers.

---

## Part 1 — `ai` component

### 1.1 Design
- [ ] `components/ai/` exposing `local ai = require("ai")`.
- [ ] `ai.client({provider, apiKey, model, baseUrl?, headers?, ...})` → client with `:generate(req)` (full), `:stream(req, onEvent)` (streaming), `:image(req)`, `:embed(req)` (where supported), `:countTokens(req)` (where supported).
- [ ] `ai.audio({provider="elevenlabs", apiKey, baseUrl?})` → audio client with `:tts(req)` (returns audio bytes), `:ttsStream(req, onChunk)` (chunked audio), `:stt(req)` (transcription), `:voices()`, `:speechToSpeech(req)`, `:soundEffect(req)`. OpenAI and Gemini also expose audio (OpenAI `/v1/audio/speech` + `/v1/audio/transcriptions`, Gemini audio in/out) — expose those too, with ElevenLabs as the dedicated, full-featured audio provider.
- [ ] Transport: the project `http.client` (after Part 3) — `client.request` returning `{status, headers, body}` and `client.stream` delivering the body in chunks via a callback. Binary bodies (audio/image) returned intact; multipart bodies (STT/STS/voice-clone uploads) assembled by the ai component and sent as the request body. SSE decoding (split events, multi-line `data:`, ignore comment lines) lives in the ai component on top of the chunk callback.
- [ ] **Two wire families + adapters**: (a) **OpenAI Chat Completions** baseline covers OpenAI, Grok, DeepSeek, Kimi, Mistral, Groq, Together, OpenRouter, Ollama-`/v1`; (b) **native adapters** for Anthropic Messages, Google Gemini, and Ollama-native `/api/chat`. Optional OpenAI Responses adapter for hosted tools/state.
- [ ] Normalized request `{model, messages[], system?, temperature?, maxTokens?, topP?, stop?, tools?, toolChoice?, responseFormat?, reasoning?, stream?, extra?}`; message `{role, content=string|parts[]}`; parts text/image/tool_call/tool_result.
- [ ] Normalized response `{text, finishReason, toolCalls[], reasoning?, usage={inputTokens,outputTokens,totalTokens,...}, raw}`.
- [ ] Normalized stream events: `text_delta`, `tool_call_delta`, `reasoning_delta`, `done{finishReason,usage}`, `error`.
- [ ] `extra`/`raw` passthrough so provider-specific request fields and response data are never hidden.
- [ ] Keys from caller or `process.env`; never persisted or logged.

### 1.2 Provider matrix (verified 2026-06-21)

| Provider | Wire | Base URL | Auth | Image gen | Reasoning surface |
|---|---|---|---|---|---|
| OpenAI | Responses + Chat | `https://api.openai.com/v1` | `Bearer` | yes | `reasoning.effort` |
| Anthropic | Messages | `https://api.anthropic.com` | `x-api-key` + `anthropic-version: 2023-06-01` | **no** | adaptive `thinking` → `thinking` blocks |
| Gemini | generateContent | `https://generativelanguage.googleapis.com` (`v1beta`) | `x-goog-api-key` / `?key=` | yes (native) | `thinkingLevel` / `thinkingConfig` |
| xAI Grok | Chat + Responses + Messages | `https://api.x.ai/v1` | `Bearer` | yes | `reasoning_effort` / `reasoning.effort` |
| Moonshot/Kimi | Chat (+ Anthropic) | `https://api.moonshot.ai/v1` (+`.cn`) | `Bearer` | no | `reasoning_content` |
| DeepSeek | Chat (+ Anthropic) | `https://api.deepseek.com` | `Bearer` | no | `reasoning_content` |
| Mistral | Chat + Agents | `https://api.mistral.ai/v1` | `Bearer` | via agent tool | typed `ThinkChunk` list |
| Groq | Chat | `https://api.groq.com/openai/v1` | `Bearer` | no | `reasoning` field |
| Together | Chat + images | `https://api.together.xyz/v1` | `Bearer` | yes (FLUX) | `reasoning` (gpt-oss) |
| OpenRouter | Chat (+ Messages) | `https://openrouter.ai/api/v1` | `Bearer` | varies | `reasoning` object |
| Ollama | Chat-`/v1` + native | `http://localhost:11434` | none | no | `message.thinking` |

### 1.3 OpenAI (verified)
- `Authorization: Bearer`; optional `OpenAI-Organization`/`OpenAI-Project`. Responses `POST /v1/responses` (current/recommended, stateful) and Chat `POST /v1/chat/completions` (fully supported). Assistants API retires 2026-08-26 — do not target.
- Responses: `input`+`instructions`, `max_output_tokens`, `reasoning:{effort,summary}`, `text:{format,verbosity}`, typed `output[]`+`output_text`, usage `input_tokens/output_tokens`. Streaming = typed semantic events (`response.output_text.delta`, `response.function_call_arguments.delta`, terminal `response.completed/incomplete/failed`), **no `[DONE]`**.
- Chat: `messages[]`, `max_completion_tokens`, `response_format`, `choices[].message`, usage `prompt_tokens/completion_tokens`. Streaming = `chat.completion.chunk` `choices[].delta`, terminator `data: [DONE]`, opt-in usage via `stream_options.include_usage`.
- Tools: Chat nests `function:{...}` + returns `tool_calls[]` (arguments JSON string) + result `{role:"tool",tool_call_id,content}`; Responses flattens `{type:"function",name,...}` + `function_call`(`call_id`) + result `{type:"function_call_output",call_id,output}`. `tool_choice` auto/none/required/specific, `parallel_tool_calls`. Responses hosted tools: web_search, file_search, code_interpreter, image_generation, computer_use, mcp.
- Structured output: Chat `response_format:{type:"json_schema",json_schema:{name,strict,schema}}`; Responses `text:{format:{type:"json_schema",...}}`. Strict: all props `required`, `additionalProperties:false`, root object.
- Vision: Chat `{type:"image_url",image_url:{url,detail}}`; Responses `{type:"input_image",image_url,detail}`/`file_id`.
- Image gen `POST /v1/images/generations`: GPT-Image returns `b64_json` only (`size/quality/background/output_format/output_compression/moderation`); `dall-e-3` (`n=1`, `quality` standard/hd, `style`, `response_format`, `revised_prompt`). Edits `/v1/images/edits` (mask=inpaint), variations `/v1/images/variations` (dall-e-2).
- Errors `{error:{message,type,param,code}}`; retry 429/5xx honoring `Retry-After`; `x-ratelimit-*` headers. Extras: `reasoning.effort` (none/minimal/low/medium/high/xhigh), `reasoning.summary`, `logprobs`, `seed`+`system_fingerprint`, `service_tier`, prompt caching (`prompt_cache_key`).
- Models (mid-2026): text `gpt-5.5`/`gpt-5.4`(+mini/nano), `o3`/`o4-mini`; image `gpt-image-2`/`gpt-image-1.5`/`dall-e-3`. Pin exact IDs at integration time via `GET /v1/models`.

### 1.4 Anthropic Claude (verified 2026-06-21, docs at platform.claude.com)
- `POST /v1/messages`; `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`; combine betas via `anthropic-beta`.
- Request: `model`, **`max_tokens` (required)**, `messages[]`, `system` (top-level string/blocks), `stream`, `tools`, `tool_choice`, `thinking`, `metadata`, `service_tier`, `output_config`. ⚠️ On Fable 5 / Opus 4.8/4.7 / Sonnet 4.6 `temperature/top_p/top_k` and `thinking.budget_tokens` are **rejected (400)** and prefill returns 400 — feature-detect by model.
- Response: `content[]` blocks, `stop_reason` (end_turn/max_tokens/stop_sequence/tool_use/pause_turn/refusal), `usage` (`input_tokens/output_tokens/cache_creation_input_tokens/cache_read_input_tokens/output_tokens_details.thinking_tokens/server_tool_use`). `input_tokens` is the uncached remainder.
- Blocks: `text`; `image` source base64/url/file; `document` (pdf, base64/file, optional citations); `tool_use{id,name,input}`; `tool_result{tool_use_id,content,is_error}`; `thinking{thinking,signature}` + `redacted_thinking`.
- Streaming: `message_start` → (`content_block_start` → `content_block_delta`(`text_delta`/`input_json_delta(partial_json)`/`thinking_delta`/`signature_delta`/`citations_delta`) → `content_block_stop`)* → `message_delta`(stop_reason,usage cumulative) → `message_stop`; `ping`; `error` events can arrive after the 200.
- Tools: `input_schema` (+ optional `strict`), `tool_choice` auto/any/tool/none (+`disable_parallel_tool_use`); reply with one user msg holding all `tool_result` blocks. Current server tools: `web_search_20260209`/`web_fetch_20260209`/`code_execution_20260120` (need Opus 4.8/4.7/4.6 or Sonnet 4.6), `bash_20250124`, `text_editor_20250728`, `memory_20250818`, `computer_20250124`.
- Thinking: `{"type":"adaptive","display":"summarized|omitted"}` on current models (numeric `budget_tokens` only on older); depth via `output_config.effort` (low/medium/high/xhigh/max). Streaming `thinking_delta`+one `signature_delta`; preserve `signature` when replaying.
- Prompt caching: `cache_control:{type:"ephemeral", ttl?:"1h"}` on a block or top-level; usage reports creation/read.
- **No image generation** — `ai.image()` must route image requests elsewhere.
- Token count `POST /v1/messages/count_tokens`. Errors `{type:"error",error:{type,message},request_id}` (400/401/402/403/404/413/429/500/504/529); `retry-after` + `anthropic-ratelimit-*` headers; `request-id` on every response.
- Models (2026-06-21): `claude-fable-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-opus-4-6`, `claude-sonnet-4-6`, `claude-haiku-4-5`. IDs are dateless pinned snapshots (no date suffix on 4.6+).

### 1.5 Google Gemini (verified 2026-06-21, ai.google.dev)
- Host `https://generativelanguage.googleapis.com`, use `v1beta`. Auth `x-goog-api-key` header (or `?key=`). Endpoint `/v1beta/models/{model}:{method}`.
- `:generateContent`: `contents[]` (role user/model, parts text/inlineData{mimeType,data}/fileData{mimeType,fileUri}/functionCall/functionResponse), `systemInstruction`, `generationConfig{temperature,maxOutputTokens,topP,topK,stopSequences,responseMimeType,responseSchema,responseModalities,thinkingConfig}`, `safetySettings`, `tools`, `toolConfig`, `cachedContent`. Response `candidates[].content.parts`+`finishReason`, `usageMetadata{promptTokenCount,candidatesTokenCount,thoughtsTokenCount,totalTokenCount}`, `modelVersion`.
- ⚠️ Thinking changed: Gemini 3.x/3.5 use **`thinkingConfig.thinkingLevel`** (`minimal/low/medium/high`); 2.5 series use legacy `thinkingBudget` (int); sending both → 400. `includeThoughts:true` returns thought-summary parts (`thought:true`).
- Streaming `:streamGenerateContent?alt=sse` — `data:` lines each a partial `GenerateContentResponse`; text accumulates; usage/finishReason on final chunk.
- Function calling: `tools[].functionDeclarations`; model returns `functionCall{id,name,args}`, reply `functionResponse{id,name,response}` (echo `id`; for 3.x also echo thought signatures). `toolConfig.functionCallingConfig.mode` AUTO/ANY/NONE/VALIDATED. Native tools `{googleSearch:{}}`, `{urlContext:{}}`, `{codeExecution:{}}` (combinable); grounded responses carry `groundingMetadata`.
- Structured output: `responseMimeType:"application/json"`+`responseSchema` (OpenAPI subset, `propertyOrdering`); enum via `text/x.enum`.
- Multimodal: `inlineData` base64 (<~20 MB total) or Files API (`POST /upload/v1beta/files` → `fileData.fileUri`, ~48 h).
- Image gen: **native (recommended)** — `:generateContent` with image model + `responseModalities:["TEXT","IMAGE"]`, image returned as `inlineData` part, `imageConfig{aspectRatio,imageSize 1K/2K/4K}`; models `gemini-3.1-flash-image`, `gemini-3-pro-image`, `gemini-2.5-flash-image`. **Imagen `:predict`** (`instances[].prompt`, `parameters{sampleCount,aspectRatio,personGeneration}` → `predictions[].bytesBase64Encoded`) is **deprecated, shuts down 2026-08-17** — prefer native.
- Errors `{error:{code,message,status}}` (400 INVALID_ARGUMENT / 403 / 404 / 429 RESOURCE_EXHAUSTED / 500 / 503); retry 429/503. Rate limits are tier/environment-specific — read at runtime, don't hardcode.
- Models (2026-06-21): text `gemini-3.5-flash` (default), `gemini-3.1-flash-lite`; image as above. 2.5 series + Imagen 4 on shutdown timelines — target 3.x.

### 1.6 OpenAI-compatible providers (verified 2026-06-21)
Baseline: `POST {base}/v1/chat/completions`, `Bearer`, SSE + `data: [DONE]`, `choices[].delta`, `tool_calls[]`. Per-provider deltas:
- **Grok** (`https://api.x.ai/v1`): Chat is legacy — **Responses `/v1/responses`** preferred (stateful), also Anthropic `/v1/messages`. Tool-call args stream **whole** (no deltas). `additionalProperties` defaults false. `reasoning_effort` (+`xhigh` on multi-agent), reasoning models reject penalties/stop. Image `POST /v1/images/generations` model `grok-imagine-image`/`-quality` — uses **`aspect_ratio`+`resolution`** (no `size`/`quality`). Search via built-in tools `web_search`/`x_search`/`code_interpreter` (old `search_parameters` retired 2026-01-12). Models `grok-4.3`, `grok-4.20-*`.
- **Moonshot/Kimi** (`https://api.moonshot.ai/v1` and `.cn` — separate accounts/keys): also Anthropic endpoint `/anthropic` (remaps `temp*0.6`). Function `strict` defaults true. Context caching: auto prefix for `kimi-k2.*` (`cached_tokens`, `prompt_cache_key`), explicit `POST /v1/caching` + `role:"cache"` for `moonshot-v1-*`. Partial/prefix mode (`partial:true` on trailing assistant msg; response omits the prefix). Reasoning via `thinking` object → `reasoning_content` (round-trip before tool calls). `max_completion_tokens`, temp 0–1. Models `kimi-k2.7-code`, `kimi-k2.6`, `moonshot-v1-{8k,32k,128k}`.
- **DeepSeek** (`https://api.deepseek.com`, also `/anthropic`): V4 shipped — `deepseek-v4-flash`/`deepseek-v4-pro` (dual-mode); **`deepseek-chat`/`deepseek-reasoner` retire 2026-07-24**. `thinking` object (default enabled) + `reasoning_effort` high/max; CoT in `reasoning_content` (strip before re-feeding); thinking mode silently ignores sampling params. Only `json_object`. No image.
- **Mistral** (`https://api.mistral.ai/v1`): `tool_choice` adds `any`; `json_object`+`json_schema`. Reasoning as typed **ThinkChunk/TextChunk list** (no `reasoning_content`; streaming `delta.content` becomes a list) — needs a dedicated parser. Image only via Agents API tool `{type:"image_generation"}`. Models `mistral-medium-3-5`, `mistral-large-3`, `mistral-small-4`.
- **Groq** (`https://api.groq.com/openai/v1`): `json_object`+`json_schema(strict)`. Reasoning via `reasoning_format`/`include_reasoning` → `reasoning` field; `reasoning_effort`. No image. `N` must be 1; `temperature:0`→`1e-8`; no logprobs/logit_bias. Models `openai/gpt-oss-120b`, `qwen/qwen3.6-27b`, `groq/compound`.
- **Together** (`https://api.together.xyz/v1`): `json_object`+`json_schema`. Image `POST /v1/images/generations` FLUX (`black-forest-labs/FLUX.2-*`, params `prompt/negative_prompt/steps/n/width/height/seed/response_format`, edit via `image_url`). `vendor/model` IDs.
- **OpenRouter** (`https://openrouter.ai/api/v1`): SSE emits `: OPENROUTER PROCESSING` comment lines (ignore); **mid-stream errors inline with HTTP 200 + `finish_reason:"error"`**. `reasoning` object (effort enum incl xhigh/minimal/none) → `reasoning` field. Headers `HTTP-Referer`+`X-Title`; body `provider` routing object. `vendor/model` IDs.
- **Ollama** (`http://localhost:11434`): `/v1/chat/completions` (SSE+`[DONE]`, no `tool_choice`/`logprobs`). Native `/api/chat` is **NDJSON** (no `data:`, no `[DONE]`, final `"done":true`+`done_reason`, delta in `message` not `choices[].delta`), structured via `format` (json or schema), reasoning via `think`→`message.thinking`, tool result `role:"tool"`+`tool_name`, sampling in `options`. Model `name:tag`.

### 1.6b Audio — ElevenLabs (verified 2026-06-21, elevenlabs.io/docs)
- Base `https://api.elevenlabs.io`; auth header `xi-api-key`. `v1` prefix for almost everything (voices list moved to `GET /v2/voices`). Browser/client use can mint single-use tokens via `POST /v1/tokens/create`.
- **TTS** `POST /v1/text-to-speech/{voice_id}` (and `/stream` for chunked audio). Query `output_format` (default `mp3_44100_128`), `optimize_streaming_latency` (0–4). Body `{text (req), model_id, language_code, voice_settings{stability,similarity_boost,style,use_speaker_boost,speed}, seed, previous_text/next_text, previous_request_ids/next_request_ids, apply_text_normalization}`. Response = raw audio bytes (octet-stream); `/stream` = same bytes chunked. Models `eleven_v3` (most expressive), `eleven_multilingual_v2` (default), `eleven_flash_v2_5` (~75 ms low latency); `*_v1` removed 2026-07-09.
- **Realtime TTS WebSocket** `wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input` (single-context) and `/multi-stream-input` (multi-context with `context_id`): init msg (`text:" "`, `voice_settings`, `generation_config.chunk_length_schedule`, auth), text chunks (`{text, try_trigger_generation, flush}`), close (`{text:""}`); server → `{audio:<base64>, alignment, normalizedAlignment}` then `{isFinal:true}`. (WebSocket needs a ws client — defer to a later phase; HTTP `/stream` covers low-latency well.)
- **STT (Scribe)** `POST /v1/speech-to-text` (multipart): `model_id` (`scribe_v2`, req), `file` or `cloud_storage_url`, `language_code`, `tag_audio_events`, `num_speakers`, `timestamps_granularity` (none/word/character), `diarize`, `file_format`. Response `{language_code, language_probability, text, words[]{text,type,start,end,speaker_id,characters[]}}`. Realtime STT WebSocket `wss://.../v1/speech-to-text/realtime` with `scribe_v2_realtime`.
- **Voices** `GET /v2/voices` (search/page_size/sort/category/voice_ids), `GET /v1/voices/{id}`, settings get/edit; **voice design** `POST /v1/text-to-voice/design` (+ `/create`); **instant clone** `POST /v1/voices/add` (multipart); **PVC** `POST /v1/voices/pvc/*`.
- **Other**: speech-to-speech `POST /v1/speech-to-speech/{voice_id}` (multipart audio, `model_id` default `eleven_english_sts_v2`, `+/stream`); sound effects `POST /v1/sound-generation` (`text, duration_seconds, prompt_influence, model_id eleven_text_to_sound_v2`); audio isolation `POST /v1/audio-isolation`; dubbing `POST /v1/dubbing` (async `dubbing_id` → poll → `GET /v1/dubbing/{id}/audio/{lang}`).
- **Output formats**: `mp3_44100_{32..192}`, `mp3_22050_32`, `mp3_24000_48`, `pcm_{8000..48000}` (raw 16-bit LE mono), `ulaw_8000`/`alaw_8000` (telephony), `opus_48000_{32..192}`.
- **Errors** `{detail:{type,code,message,request_id}}`; 400/401/402/403/404/409/429/500/503. 429 split: `rate_limit_exceeded` (backoff) vs `concurrent_limit_exceeded` (wait for in-flight; per-plan concurrency 2→15+). Usage via `GET /v1/usage/character-stats` + `GET /v1/user/subscription` (no standardized per-response credit header). `request_id` on responses.
- [ ] Audio bodies are binary — the transport must return raw bytes untouched; `ai.saveAudio(bytes, path)` via fs; STT/STS/clone use multipart bodies (the transport needs a multipart encoder).

### 1.7 Deviations the client must handle (consolidated)
- [ ] **Base/path**: Groq `/openai/v1`, OpenRouter `/api/v1`, DeepSeek optional `/v1`, Moonshot two regional clusters, Together `.xyz`.
- [ ] **Streaming terminators**: SSE+`[DONE]` (most), OpenAI Responses terminal-event (no sentinel), Anthropic event sequence, Gemini `?alt=sse` chunks, Ollama-native NDJSON `done:true`. OpenRouter comment lines + inline 200 errors. Grok whole-chunk tool args.
- [ ] **Reasoning surfaces** (all different): `reasoning_content` (DeepSeek/Kimi), `reasoning` field (Groq/OpenRouter), `message.thinking` (Ollama), typed chunk list (Mistral), `thinking` blocks (Anthropic), `thoughtsTokenCount`/thought parts (Gemini). Effort enums vary (`xhigh`/`minimal`/`none`/`max`).
- [ ] **Structured output**: full `json_schema` (most) vs `json_object` only (DeepSeek) vs Gemini `responseSchema` vs Ollama `format`.
- [ ] **Tools**: Mistral `any`; Ollama `tool_name`/no id/no `tool_choice`; Kimi/Mistral default `strict:true`; server-side tools on xAI/Mistral/Groq/Anthropic/Gemini/OpenAI.
- [ ] **Image gen**: OpenAI-style (OpenAI, Together, xAI with `aspect_ratio`/`resolution`), Gemini native modality, Imagen `:predict`, Mistral agent tool; none on DeepSeek/Kimi/Groq/OpenRouter/Ollama.
- [ ] **Model IDs**: namespaced (OpenRouter/Together), `name:tag` (Ollama), plus deprecation churn (DeepSeek 2026-07-24, Groq Llama 2026-08-16) — fetch `GET /v1/models` at runtime where possible.

### 1.8 Streaming (built on Part 3)
- [ ] SSE line parser (accumulate `event:`/`data:` to blank line, multi-line `data:`, ignore comment lines).
- [ ] NDJSON parser for Ollama-native.
- [ ] Per-family event decoding → normalized stream events; incremental tool-call argument assembly; reasoning deltas; handle inline-error-with-200 (OpenRouter) and terminal-event vs `[DONE]`.
- [ ] Early cancellation of a stream.

### 1.9 `ai` deliverables
- [ ] `components/ai/init.lua` + adapters (`openai_chat`, `openai_responses`, `anthropic`, `gemini`, `ollama_native`) + provider registry with per-provider defaults/headers/quirks.
- [ ] Tool-calling normalization across all families; image gen + `ai.saveImage` (crypto.base64Decode + fs.writeFile).
- [ ] Error mapping to a uniform error; retry 429/5xx honoring `retry-after` (needs Part 3 headers).
- [ ] Examples per capability: text full, text stream, tools round trip, vision input, structured output, image gen + save, reasoning/thinking, base-url override for a compatible provider.
- [ ] Tests via an injectable fake transport (no network); per-adapter request-build + response/stream-parse unit tests; opt-in live smoke gated on env keys (skipped in CI).
- [ ] `components/ai/README.md` (capability table, per-provider notes) per project comment/doc style.

---

## Part 2 — `scheduler` component (store = `vdo`)

### 2.1 Design
- [ ] `components/scheduler/` exposing `local scheduler = require("scheduler")`, persisting through `vdo` (`vdo.connect(dsn)`, default `sqlite:` file e.g. `sqlite:./.varn/scheduler.db`; mysql/pgsql via DSN for shared/multi-node later).
- [ ] **Named handlers + serializable payloads** (closures are never persisted): `scheduler.handler(name, fn)` registers at startup; tasks store handler name + JSON payload.
- [ ] Triggers: `scheduler.enqueue(name, payload, opts)` (immediate), `scheduler.schedule(name, payload, runAt, opts)` (datetime), `scheduler.every(name, payload, intervalMs, opts)` (interval). `opts`: `id?/priority?/maxAttempts?/backoff?/unique?`.
- [ ] Management: `scheduler.cancel(id)`, `scheduler.remove(id)`, `scheduler.get(id)`, `scheduler.list(filter)`, `scheduler.pause()/resume()`, `scheduler.start()` (boots tick loop + recovery, idempotent).

### 2.2 Store schema (vdo / SQL)
- [ ] `db:exec` DDL on first start (idempotent `CREATE TABLE IF NOT EXISTS`).
- [ ] `tasks(id TEXT PRIMARY KEY, name TEXT, payload TEXT, state TEXT, priority INTEGER, run_at INTEGER, interval_ms INTEGER NULL, attempts INTEGER, max_attempts INTEGER, backoff TEXT, lease_epoch TEXT NULL, heartbeat_at INTEGER NULL, last_error TEXT NULL, result TEXT NULL, created_at INTEGER, updated_at INTEGER)`.
- [ ] `runs(id TEXT PRIMARY KEY, task_id TEXT, attempt INTEGER, started_at INTEGER, finished_at INTEGER NULL, state TEXT, error TEXT NULL, result TEXT NULL)` for history.
- [ ] Index `(state, run_at)` for due-task polling. Use `:name` bound prepared statements. Use `db:transaction(fn)` for every state transition so claim is atomic.

### 2.3 State machine
- States `queued`, `scheduled`, `running`, `success`, `failed`, `retrying`, `cancelled`.
- Transitions: scheduled→queued (due) ; queued→running (atomic claim) ; running→success ; running→retrying→queued (attempt<max, after backoff) ; running→failed (attempt≥max) ; running→queued (orphan reclaim on boot) ; {queued,scheduled,retrying}→cancelled. A repeating task on success inserts a fresh `scheduled` row at `now+interval_ms`.
- [ ] Compare-and-set update (`UPDATE ... WHERE id=:id AND state=:expected`) inside a transaction so a claim cannot double-run.

### 2.4 Crash recovery / resilience (the core requirement)
- [ ] On `start()`, generate a fresh **boot epoch** id. Any row in `running` with `lease_epoch != current` was orphaned by a kill/restart → reset to `queued` (this is the single-process reaper that satisfies "a killed in-progress task returns to queued").
- [ ] Claim writes `state=running, lease_epoch=current, heartbeat_at=now, started_at=now` in one transaction; only the owner settles it.
- [ ] Optional in-run reaper: long handlers update `heartbeat_at`; a `stuck_running_timeout` reclaims a stale-heartbeat task even without a restart. Document **at-least-once → handlers must be idempotent**.
- [ ] Full in-memory view rebuilt from `tasks` on boot, so the list survives restarts.

### 2.5 Triggers + polling
- [ ] Tick loop `async.spawn(function() while running do tick(); async.sleep(pollMs):await() end end)` (default ~250–1000 ms; the pending sleep keeps the process alive).
- [ ] Each tick: promote due `scheduled`→`queued`, then claim+dispatch `queued` up to a concurrency limit, ordered by `priority` then `run_at`.
- [ ] Misfire/coalesce: when many interval runs were missed during downtime, coalesce to one run and re-arm from `now` (configurable `coalesce`/`misfireGraceMs`).
- [ ] Run blocking handler bodies off the event-loop thread (wrap in `runOnPool`/ioPool); settle state on the event loop.

### 2.6 Worker model
- [ ] Configurable max concurrent running tasks; a claimed task counts until settled.
- [ ] Retry with exponential backoff + jitter; `max_attempts`; terminal `failed` records `last_error` + full `runs` history.

### 2.7 Must NOT
- ❌ Persist closures — only `{handler name + JSON payload}`. ❌ Block the event-loop thread with handler work. ❌ Swallow handler errors (record + transition). ❌ Assume multi-process without real leases (single-process now; multi-node via a shared mysql/pgsql DSN + leases is a documented future extension).

### 2.8 `scheduler` deliverables
- [ ] `components/scheduler/init.lua` (vdo-backed store, tick loop, recovery, handler registry).
- [ ] Examples: immediate, run-at-datetime, every-interval, cancel/remove, query status+history, retry-on-error, and a "kill mid-task → returns to queued on restart" demo.
- [ ] Tests (in-memory `sqlite::memory:` for determinism): state transitions, due selection, **crash recovery** (seed an orphaned `running` row from a prior epoch → assert reset to `queued`), retry/backoff, interval re-arm + coalescing, cancel/remove, history retention/pruning.
- [ ] `components/scheduler/README.md` (capability table, durability guarantees, named-handler + idempotency contract) per project style.

---

## Part 3 — Core change: streaming + headers in the HTTP client — DONE ✅

Done and validated against the real OpenAI API (text + streaming + rate-limit headers visible); CI test `modules/http/lua/tests/http_client_stream_test.lua` covers streaming locally. `http.client.request` resolves `{status, headers, body}` (the `VARN/1` wire is gone), `http.client.stream(opts, onChunk)` streams body chunks with `opts.onResponse(status, headers)`. Also fixed a pre-existing TLS gap: the bundled OpenSSL had no CA trust store, so verified https to real hosts failed — added `resolveCaBundle()` (honors `SSL_CERT_FILE`, then probes OS bundle paths) to both the http client and `socket.tls` contexts.

Original scope (for reference): extend the real client rather than hand-rolling HTTP. Bounded change in `HttpClientModule` / `HttpClientPerform` / `PocoClientExchange` (Poco already exposes the response `istream` + `HTTPResponse` headers; today we read it all and drop the headers).

- [ ] **Expose response headers + clean up the wire.** Replace the `VARN/1 <status> <len>\n<body>` wire-string with the promise resolving (via `resolveCustom`) to a Lua table `{status, headers, body}`. Update `HttpClientModule`'s prelude `makeResponse`/`parseWire` accordingly (drop `parseWire`).
- [ ] **Streaming API.** Add `client.stream(opts, {onResponse=fn(status, headers), onChunk=fn(chunk)})` returning a promise that resolves when the stream ends and rejects on error. `onResponse` fires once after the response line/headers; `onChunk` fires per body chunk.
- [ ] **Chunk marshaling.** In `PocoClientExchange`, after `receiveResponse` read the body `istream` in chunks on `ioPool`; for each chunk, post a job to the event loop (`rt.mainLoop().post`) that invokes the stored Lua callback ref with the chunk (copy the bytes into the job). Reuse the `runOnPool`/Promise plumbing and the registry-ref pattern from `AsyncModule`/`Promise`. Keep `maxResponseBytes` (as a cumulative guard) and timeout; support cancellation to stop reading.
- [ ] **Chunked/identity bodies** are handled by Poco's `istream`; the chunk callback sees decoded body bytes (binary-safe).
- [ ] **wasm**: native (Poco) first; the emscripten fetch driver's incremental/streaming reader is a follow-up (browser AI is server-side anyway).
- [ ] Tests against a local chunked/SSE HTTP server (the http/socket test harness) on Windows/Linux/macOS CI; project comment/format rules; wrap lambdas in `// clang-format off/on`.

---

## Part 4 — Cross-cutting
- [ ] Both components follow the `components/` pattern over `http`/`json`/`crypto`/`fs`/`async`/`vdo`.
- [ ] Comment + doc style per project rules (single-line lowercase `//`/`--`, no trailing period/colon, no `;`-split, English, intent-not-restatement, no header member comments; objective READMEs with a capabilities section; usage examples in docs).
- [ ] Per-capability examples + individual tests wired into the runner; live-network tests gated on env keys, skipped in CI.
- [ ] Server-side `ai` demo for the site (wasm browser cannot reach provider APIs without a proxy/keys).

## Build order
1. **Part 3** streaming + response headers in the HTTP client, replacing the `VARN/1` wire with a `{status, headers, body}` table → unblocks `ai` streaming and `retry-after`, benefits the whole project.
2. **`ai`** — OpenAI Chat baseline + the compatible providers, then Anthropic + Gemini native adapters, then streaming, then image gen, then audio (ElevenLabs), then native extras.
3. **`scheduler`** — vdo store + state machine + recovery + tick loop, then triggers, retries, history, then examples/tests.

## Remaining open question
- Provider breadth for `ai` v1: ship OpenAI + Claude + Gemini + the OpenAI-compatible adapter (covers Grok/Kimi/DeepSeek/Groq/Together/OpenRouter/Ollama) first, with Mistral's typed-reasoning parser and Ollama-native as fast-follows?
