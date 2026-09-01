# 🤖 AI
One client for every LLM provider: you name the model as `provider/model`, pass a list of messages, and read an OpenAI-shaped response back — whatever wire the provider actually speaks underneath.

```lua
local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.completion({
        model = "openai/gpt-4o-mini",
        messages = { { role = "user", content = "Why is the sky blue?" } },
    })

    print(response.choices[1].message.content)
end)
```

Switching provider is switching that one string:

```lua
ai.completion({ model = "anthropic/claude-sonnet-4-5", messages = messages, max_tokens = 1024 })
ai.completion({ model = "gemini/gemini-2.5-pro", messages = messages })
ai.completion({ model = "groq/llama-3.3-70b-versatile", messages = messages })
ai.completion({ model = "bedrock/anthropic.claude-sonnet-4-5-v1:0", messages = messages, aws_region_name = "us-east-1" })
```

Every call yields on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`). Native-only — it depends on the native `http` module, unavailable in the browser.

## Calls

| Function | What it does |
|---|---|
| `ai.completion(request)` | Chat completion, returning an OpenAI `chat.completion`. |
| `ai.completion(request, onChunk)` | The same call streamed — `onChunk` receives each `chat.completion.chunk`, and the assembled response is still returned. |
| `ai.messages(request)` | The same chat asked with content blocks and a `system` beside the conversation, replying with `content[]` blocks and `stop_reason`. |
| `ai.responses(request)` | The same chat asked with a single `input` and `instructions`, replying with `output[]` items and `output_text`. |
| `ai.embedding(request)` | Embeddings for `input`. |
| `ai.imageGeneration(request)` | Images for `prompt`. |
| `ai.transcription(request)` | Speech to text for the audio bytes in `file`. |
| `ai.speech(request)` | Text to speech for `input`, returning the raw audio bytes. |
| `ai.moderation(request)` | Moderation for `input`. |
| `ai.rerank(request)` | Rerank `documents` against `query`. |
| `ai.providers()` | The sorted list of provider slugs this client can address. |
| `ai.saveImage(image, path)` | Write one entry of an `imageGeneration` result to disk, decoding base64 or downloading a url. |
| `ai.saveAudio(bytes, path)` | Write the bytes returned by `speech` to disk. |
| `ai.fileCreate(request)` | Upload the jsonl a batch reads from. |
| `ai.batchCreate` / `batchRetrieve` / `batchList` / `batchCancel` / `batchResults` | Run a set of requests offline and collect the decoded records. |

`completion`, `messages` and `responses` are three surfaces over the same capability — they differ only in the shape you write and read, and every provider serves all three because the client converts between them. All three take the streaming handler.

## The request

`model` is required and everything else is passed through to the provider untouched, so any OpenAI parameter works without this component knowing about it — `temperature`, `top_p`, `max_tokens`, `stop`, `n`, `seed`, `tools`, `tool_choice`, `response_format`, `stream_options`, and anything a provider adds later.

These keys are consumed here instead of being sent on the wire:

| Key | What it does |
|---|---|
| `api_key` | The credential, otherwise read from the provider's environment variable. |
| `api_base` | Override the endpoint, otherwise the provider's `<SLUG>_API_BASE` variable or its default. |
| `api_version` | The API version, used by `azure` and `watsonx`. |
| `extra_headers` | Headers merged over the ones the adapter builds. |
| `timeout` | Request timeout in seconds. |
| `aws_region_name`, `aws_access_key_id`, `aws_session_token` | Bedrock credentials and region. |
| `vertex_project`, `vertex_location` | Vertex AI project and region. |
| `iam_url` | The watsonx token exchange endpoint, for a Cloud Pak deployment. |

## Naming the model

`provider/model` selects the provider from the registry and sends the rest as the model. A name with no known provider prefix is sent to `openai`, so `"gpt-4o"` and `"openai/gpt-4o"` mean the same thing. Only the first segment is the provider, so `"openrouter/anthropic/claude-sonnet-4"` reaches OpenRouter asking for `anthropic/claude-sonnet-4`.

## Providers

127 provider slugs. Most speak the OpenAI wire and differ only in endpoint and credential variable; the rest have a real adapter that translates in both directions:

| Adapter | Providers |
|---|---|
| `openai` | `openai` and the 100+ OpenAI-compatible providers — `groq`, `xai`, `deepseek`, `mistral`, `together_ai`, `fireworks_ai`, `openrouter`, `perplexity`, `moonshot`, `cerebras`, `ollama`, `vllm`, `lm_studio`, and the rest |
| `anthropic` | `anthropic`, `anthropic_text` |
| `gemini` | `gemini`, `vertex_ai`, `vertex_ai_beta` |
| `bedrock` | `bedrock`, `sagemaker`, `sagemaker_chat` — signed with AWS Signature Version 4, streaming over the binary event protocol |
| `azure` | `azure`, `azure_text` — deployment in the path, `api-key` header |
| `cohere` | `cohere`, `cohere_chat` |
| `watsonx` | `watsonx`, `watsonx_text` — exchanges the API key for an IAM token and caches it |
| `replicate` | `replicate` |
| `elevenlabs` | `elevenlabs` |
| `deepgram` | `deepgram` |
| `image` | `fal_ai` (which also serves chat), `stability`, `black_forest_labs` |

A provider with no fixed endpoint (`databricks`, `litellm_proxy`, `hosted_vllm`, `snowflake`, `oci`, and the other self-hosted ones) names the variable to set when it is missing rather than guessing one.

Every provider that serves chat also streams it, including `bedrock`, whose stream arrives as the AWS binary event protocol and is decoded frame by frame rather than as server-sent events.

## Reference, examples, and tests

The full reference is [docs/ai.md](../docs/ai.md). Runnable examples live in [examples/](examples/) and the tests in [tests/](tests/).
