# 🤖 AI
One client for every LLM provider. You name the model as `provider/model` and pass a list of messages; you get an OpenAI-shaped response back, whatever wire the provider speaks underneath.

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

Changing provider is changing that one string, and nothing else about the call moves:

```lua
ai.completion({ model = "anthropic/claude-sonnet-4-5", messages = messages, max_tokens = 1024 })
ai.completion({ model = "gemini/gemini-2.5-pro", messages = messages })
ai.completion({ model = "cohere/command-a-03-2025", messages = messages })
ai.completion({ model = "bedrock/anthropic.claude-sonnet-4-5-v1:0", messages = messages, aws_region_name = "us-east-1" })
```

Every call yields on the event loop, so the whole lifecycle must live inside an async coroutine (`async.run` / `async.spawn`). Native-only — it depends on the native `http` module, unavailable in the browser.

## Naming the model

The model string is `provider/model`. The first segment selects the provider from the registry and everything after it is sent as the model, so `"openrouter/anthropic/claude-sonnet-4"` reaches OpenRouter asking for `anthropic/claude-sonnet-4`.

A name whose first segment is not a known provider goes to `openai`, so `"gpt-4o"` and `"openai/gpt-4o"` are the same call.

## The request

`model` is required. Everything else is forwarded to the provider untouched, so any OpenAI parameter works without this component knowing it exists — `temperature`, `top_p`, `max_tokens`, `stop`, `n`, `seed`, `tools`, `tool_choice`, `response_format`, and whatever a provider adds next.

These keys are consumed by the client and never reach the wire:

| Key | What it does |
|---|---|
| `api_key` | The credential. Falls back to the provider's environment variable. |
| `api_base` | Override the endpoint. Falls back to the provider's `<SLUG>_API_BASE` variable, then its default. |
| `api_version` | The API version, used by `azure` and `watsonx`. |
| `extra_headers` | Headers merged over the ones the adapter builds, so they win. |
| `timeout` | Request timeout in seconds. |
| `aws_region_name` | Bedrock region, or `AWS_REGION`. |
| `aws_access_key_id` | Bedrock access key, or `AWS_ACCESS_KEY_ID`. |
| `aws_session_token` | Bedrock session token, or `AWS_SESSION_TOKEN`. |
| `vertex_project` | Vertex AI project id. |
| `vertex_location` | Vertex AI region, which also selects the regional host. |
| `iam_url` | The watsonx token exchange endpoint, for a Cloud Pak deployment. |

## Three ways to ask

The same chat capability is reachable through three request surfaces. They differ only in the shape you write and read; every provider serves all three because the client converts between them.

| Call | Shape |
|---|---|
| `ai.completion(request)` | Messages with a `system` turn, replying with `choices[].message`. |
| `ai.messages(request)` | Content blocks with `system` beside the conversation, replying with `content[]` blocks and `stop_reason`. |
| `ai.responses(request)` | A single `input` with `instructions`, replying with `output[]` items and `output_text`. |

```lua
-- the same question, three surfaces, any provider
ai.completion({ model = m, messages = { { role = "user", content = "hi" } } })
ai.messages({ model = m, system = "be brief", messages = { { role = "user", content = { { type = "text", text = "hi" } } } }, max_tokens = 64 })
ai.responses({ model = m, instructions = "be brief", input = "hi" })
```

## Completion

`ai.completion(request)` returns an OpenAI `chat.completion`:

```lua
{
    id = "chatcmpl-...",
    object = "chat.completion",
    created = 1767225600,
    model = "gpt-4o-mini",
    choices = {
        {
            index = 0,
            message = { role = "assistant", content = "...", tool_calls = { ... } },
            finish_reason = "stop",
        },
    },
    usage = { prompt_tokens = 12, completion_tokens = 24, total_tokens = 36 },
}
```

`finish_reason` is normalised to `stop`, `length`, `tool_calls` or `content_filter` even when the provider spells it differently — Anthropic's `end_turn`, Gemini's `STOP` and Cohere's `COMPLETE` all arrive as `stop`.

A model that reasons puts its trace in `message.reasoning_content` when the provider exposes one.

### Streaming

Pass a handler as the second argument. It receives each `chat.completion.chunk`, and the call still returns the fully assembled response, so nothing has to be accumulated by hand:

```lua
local response = ai.completion({
    model = "anthropic/claude-sonnet-4-5",
    messages = messages,
    max_tokens = 1024,
}, function(chunk)
    io.write(chunk.choices[1].delta.content or "")
end)

print(response.choices[1].message.content)
```

Streamed tool calls are assembled too: the fragments a provider sends arrive as deltas and the returned response carries the complete `tool_calls` with their arguments joined. `ai.messages` and `ai.responses` take the same handler.

Every provider that serves chat also streams it, whatever it streams over: server-sent events for most, the AWS binary event protocol for `bedrock`, and a follow-up job url for `replicate`. The chunks reaching the handler are the same shape in all three cases.

### Tools

Tool definitions and tool results use the OpenAI shape on every provider; the adapter translates them:

```lua
local tools = {
    {
        type = "function",
        ["function"] = {
            name = "get_weather",
            description = "Current weather for a city",
            parameters = { type = "object", properties = { city = { type = "string" } }, required = { "city" } },
        },
    },
}

local first = ai.completion({ model = model, messages = messages, tools = tools })
local call = first.choices[1].message.tool_calls[1]

messages[#messages + 1] = first.choices[1].message
messages[#messages + 1] = { role = "tool", tool_call_id = call.id, content = result }
```

Gemini gives a function call no id of its own, so the client synthesizes one to keep that round trip addressable.

## Other calls

| Function | What it does |
|---|---|
| `ai.embedding(request)` | Embeddings for `input`, returning `{ object = "list", data = { { embedding = { ... } } } }`. |
| `ai.imageGeneration(request)` | Images for `prompt`, returning `{ created, data }` where each entry carries `b64_json` or `url`. |
| `ai.transcription(request)` | Speech to text for the audio bytes in `file`, returning `{ text }`. Takes `file_name` and `content_type`. |
| `ai.speech(request)` | Text to speech for `input`, returning the raw audio bytes. |
| `ai.moderation(request)` | Moderation for `input`. |
| `ai.rerank(request)` | Rerank `documents` against `query`. |
| `ai.providers()` | The sorted list of provider slugs this client can address. |
| `ai.saveImage(image, path)` | Write one entry of an `imageGeneration` result to disk, decoding its base64 or downloading its url. |
| `ai.saveAudio(bytes, path)` | Write the bytes returned by `speech` to disk. |

A provider that does not serve one of these is refused before a request is made, naming the provider and the endpoint, rather than sending something the API would reject.

## Batches

A batch runs a set of requests offline for a fraction of the live price. The input is uploaded first, the job is polled, and the records are handed back decoded:

```lua
local uploaded = ai.fileCreate({ model = "openai/gpt-4o", file = jsonlContents, file_name = "in.jsonl" })
local batch = ai.batchCreate({ model = "openai/gpt-4o", input_file_id = uploaded.id })

repeat
    async.sleep(30000):await()
    local status = ai.batchRetrieve({ model = "openai/gpt-4o", batch_id = batch.id })
until status.status == "completed"

local finished = ai.batchResults({ model = "openai/gpt-4o", batch_id = batch.id })
for _, record in ipairs(finished.results) do
    print(record.custom_id)
end
```

| Function | What it does |
|---|---|
| `ai.fileCreate(request)` | Upload the jsonl the batch reads from, returning the file whose `id` creates the batch. |
| `ai.batchCreate(request)` | Create a batch from `input_file_id`, defaulting to the chat endpoint and a 24 hour window. |
| `ai.batchRetrieve(request)` | Fetch one batch by `batch_id`. |
| `ai.batchList(request)` | List batches, taking `limit` and `after`. |
| `ai.batchCancel(request)` | Cancel one batch by `batch_id`. |
| `ai.batchResults(request)` | Fetch and decode the output, one record per entry, raising while the batch is unfinished. |

Anthropic takes its batch requests inline rather than through an uploaded file, so `ai.batchCreate` there accepts `requests` as a list of `{ custom_id, params }` and `ai.fileCreate` is not needed.

## Providers

127 slugs. Most speak the OpenAI wire and differ only in endpoint and credential variable, which is why one adapter serves so many of them; the rest have an adapter that translates in both directions.

Where the base URL column says _set `X_API_BASE`_, the provider is self-hosted or account-specific and has no default endpoint: the call raises naming that variable until `api_base` or the variable supplies one.

| Provider | Serves | Adapter | Default endpoint | Credential |
|---|---|---|---|---|
| `abliteration` | `chat` | `openai` | `https://api.abliteration.ai/v1` | `ABLITERATION_API_KEY` |
| `ai21` | `chat`, `messages`, `responses` | `openai` | `https://api.ai21.com/studio/v1` | `AI21_API_KEY` |
| `ai21_chat` | `chat`, `messages`, `responses` | `openai` | `https://api.ai21.com/studio/v1` | `AI21_API_KEY` |
| `aiml` | `chat`, `messages`, `responses`, `embeddings`, `images` | `openai` | `https://api.aimlapi.com/v1` | `AIML_API_KEY` |
| `amazon_nova` | `chat`, `messages`, `responses` | `openai` | `https://api.nova.amazon.com/v1` | `AMAZON_NOVA_API_KEY` |
| `anthropic` | `chat`, `messages`, `responses`, `batches` | `anthropic` | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` |
| `anthropic_text` | `chat`, `messages`, `responses`, `batches` | `anthropic` | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` |
| `apertis` | `chat`, `messages`, `responses` | `openai` | `https://api.stima.tech/v1` | `STIMA_API_KEY` |
| `assemblyai` | `chat`, `messages`, `responses`, `transcribe` | `openai` | `https://llm-gateway.assemblyai.com/v1` | `ASSEMBLYAI_API_KEY` |
| `auto_router` | `chat`, `messages`, `responses` | `openai` | _set `AUTO_ROUTER_API_BASE`_ | `LITELLM_PROXY_API_KEY` |
| `azure` | `chat`, `messages`, `responses`, `embeddings`, `images`, `transcribe`, `speech`, `moderation`, `batches` | `azure` | _set `AZURE_API_BASE`_ | `AZURE_API_KEY` or `AZURE_OPENAI_API_KEY` |
| `azure_ai` | `chat`, `messages`, `responses`, `embeddings`, `images`, `transcribe`, `speech`, `moderation`, `batches` | `openai` | _set `AZURE_AI_API_BASE`_ | `AZURE_AI_API_KEY` or `AZURE_API_KEY` |
| `azure_text` | `chat`, `messages`, `responses`, `transcribe`, `speech`, `moderation`, `batches` | `azure` | _set `AZURE_TEXT_API_BASE`_ | `AZURE_API_KEY` or `AZURE_OPENAI_API_KEY` |
| `baseten` | `chat`, `messages`, `responses` | `openai` | `https://inference.baseten.co/v1` | `BASETEN_API_KEY` |
| `bedrock` | `chat`, `messages`, `responses`, `embeddings`, `rerank` | `bedrock` | _derived from region/project_ | `AWS_SECRET_ACCESS_KEY` |
| `black_forest_labs` | `images` | `image` | `https://api.bfl.ai` | `BFL_API_KEY` or `BLACK_FOREST_LABS_API_KEY` |
| `bytez` | `chat`, `messages`, `responses` | `openai` | `https://api.bytez.com/models/v2` | `BYTEZ_API_KEY` |
| `cerebras` | `chat`, `messages`, `responses` | `openai` | `https://api.cerebras.ai/v1` | `CEREBRAS_API_KEY` |
| `charity_engine` | `chat`, `messages`, `responses` | `openai` | `https://api.charityengine.services/remotejobs/v2/inference` | `CHARITY_ENGINE_API_KEY` |
| `chatgpt` | `chat`, `messages`, `responses` | `openai` | `https://chatgpt.com/backend-api/codex` | `CHATGPT_API_KEY` |
| `chutes` | `chat`, `messages`, `responses` | `openai` | `https://llm.chutes.ai/v1` | `CHUTES_API_KEY` |
| `clarifai` | `chat`, `messages`, `responses` | `openai` | `https://api.clarifai.com/v2/ext/openai/v1` | `CLARIFAI_API_KEY` |
| `cloudflare` | `chat`, `messages`, `responses` | `openai` | _set `CLOUDFLARE_API_BASE`_ | `CLOUDFLARE_API_KEY` |
| `codestral` | `chat`, `messages`, `responses` | `openai` | `https://codestral.mistral.ai/v1` | `CODESTRAL_API_KEY` |
| `cognition` | `chat`, `messages`, `responses` | `openai` | `https://api.cognition.ai/v1` | `COGNITION_API_KEY` |
| `cohere` | `chat`, `messages`, `responses`, `embeddings`, `rerank` | `cohere` | `https://api.cohere.ai` | `COHERE_API_KEY` or `CO_API_KEY` |
| `cohere_chat` | `chat`, `messages`, `responses` | `cohere` | `https://api.cohere.ai` | `COHERE_API_KEY` or `CO_API_KEY` |
| `cometapi` | `chat`, `messages`, `responses`, `embeddings` | `openai` | `https://api.cometapi.com/v1` | `COMETAPI_API_KEY` |
| `compactifai` | `chat`, `messages`, `responses` | `openai` | `https://api.compactif.ai/v1` | `COMPACTIFAI_API_KEY` |
| `custom` | `chat`, `messages`, `responses` | `openai` | _set `CUSTOM_API_BASE`_ | `CUSTOM_API_KEY` |
| `custom_openai` | `chat`, `messages`, `responses`, `transcribe`, `speech`, `moderation`, `batches` | `openai` | _set `CUSTOM_OPENAI_API_BASE`_ | `OPENAI_API_KEY` |
| `dashscope` | `chat`, `messages`, `responses`, `embeddings`, `rerank` | `openai` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| `databricks` | `chat`, `messages`, `responses` | `openai` | _set `DATABRICKS_API_BASE`_ | `DATABRICKS_API_KEY` |
| `datarobot` | `chat`, `messages`, `responses` | `openai` | `https://app.datarobot.com/api/v2/genai/llmgw` | `DATAROBOT_API_TOKEN` |
| `deepgram` | `transcribe` | `deepgram` | `https://api.deepgram.com/v1` | `DEEPGRAM_API_KEY` |
| `deepinfra` | `chat`, `messages`, `responses` | `openai` | `https://api.deepinfra.com/v1/openai` | `DEEPINFRA_API_KEY` |
| `deepseek` | `chat`, `messages`, `responses` | `openai` | `https://api.deepseek.com/beta` | `DEEPSEEK_API_KEY` |
| `docker_model_runner` | `chat`, `messages`, `responses` | `openai` | `http://model-runner.docker.internal/engines/llama.cpp/v1` | `DOCKER_MODEL_RUNNER_API_KEY` |
| `elevenlabs` | `transcribe`, `speech` | `elevenlabs` | `https://api.elevenlabs.io` | `ELEVENLABS_API_KEY` |
| `empower` | `chat`, `messages`, `responses` | `openai` | `https://app.empower.dev/api/v1` | `EMPOWER_API_KEY` |
| `fal_ai` | `chat`, `messages`, `responses`, `images` | `image` | `https://fal.run` | `FAL_AI_API_KEY` or `FAL_KEY` |
| `featherless_ai` | `chat`, `messages`, `responses` | `openai` | `https://api.featherless.ai/v1` | `FEATHERLESS_AI_API_KEY` |
| `fireworks_ai` | `chat`, `messages`, `responses` | `openai` | `https://api.fireworks.ai/inference/v1` | `FIREWORKS_API_KEY` or `FIREWORKS_AI_API_KEY` |
| `friendliai` | `chat`, `messages`, `responses` | `openai` | `https://api.friendli.ai/serverless/v1` | `FRIENDLIAI_API_KEY` |
| `galadriel` | `chat`, `messages`, `responses` | `openai` | `https://api.galadriel.com/v1` | `GALADRIEL_API_KEY` |
| `gemini` | `chat`, `messages`, `responses` | `gemini` | `https://generativelanguage.googleapis.com` | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| `gigachat` | `chat`, `messages`, `responses` | `openai` | `https://gigachat.devices.sberbank.ru/api/v1` | `GIGACHAT_API_KEY` |
| `github` | `chat`, `messages`, `responses` | `openai` | `https://models.github.ai/inference` | `GITHUB_API_KEY` |
| `github_copilot` | `chat`, `messages`, `responses`, `embeddings` | `openai` | `https://api.githubcopilot.com` | `GITHUB_COPILOT_API_KEY` |
| `gradient_ai` | `chat`, `messages`, `responses` | `openai` | `https://inference.do-ai.run/v1` | `GRADIENT_AI_API_KEY` |
| `groq` | `chat`, `messages`, `responses` | `openai` | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| `heroku` | `chat`, `messages`, `responses` | `openai` | `https://us.inference.heroku.com/v1` | `HEROKU_API_KEY` |
| `hosted_vllm` | `chat`, `messages`, `responses` | `openai` | _set `HOSTED_VLLM_API_BASE`_ | `HOSTED_VLLM_API_KEY` |
| `huggingface` | `chat`, `messages`, `responses`, `embeddings`, `rerank` | `openai` | `https://router.huggingface.co/v1` | `HUGGINGFACE_API_KEY` or `HF_TOKEN` |
| `hyperbolic` | `chat`, `messages`, `responses` | `openai` | `https://api.hyperbolic.xyz/v1` | `HYPERBOLIC_API_KEY` |
| `inception` | `chat`, `messages`, `responses` | `openai` | `https://api.inceptionlabs.ai/v1` | `INCEPTION_API_KEY` |
| `infinity` | `embeddings` | `openai` | _set `INFINITY_API_BASE`_ | `INFINITY_API_KEY` |
| `jina_ai` | `embeddings`, `rerank` | `openai` | `https://api.jina.ai/v1` | `JINA_AI_API_KEY` |
| `lambda_ai` | `chat`, `messages`, `responses` | `openai` | `https://api.lambda.ai/v1` | `LAMBDA_API_KEY` |
| `lemonade` | `chat`, `messages`, `responses` | `openai` | `http://localhost:8000/api/v1` | `LEMONADE_API_KEY` |
| `libertai` | `chat`, `messages`, `responses` | `openai` | `https://api.libertai.io/v1` | `LIBERTAI_API_KEY` |
| `litellm_proxy` | `chat`, `messages`, `responses`, `embeddings`, `images` | `openai` | _set `LITELLM_PROXY_API_BASE`_ | `LITELLM_PROXY_API_KEY` |
| `llamafile` | `chat`, `messages`, `responses` | `openai` | `http://127.0.0.1:8080/v1` | `LLAMAFILE_API_KEY` |
| `lm_studio` | `chat`, `messages`, `responses` | `openai` | `http://localhost:1234/v1` | `LM_STUDIO_API_KEY` |
| `maritalk` | `chat`, `messages`, `responses` | `openai` | `https://chat.maritaca.ai/api` | `MARITALK_API_KEY` |
| `meta_llama` | `chat`, `messages`, `responses` | `openai` | `https://api.llama.com/compat/v1` | `LLAMA_API_KEY` |
| `minimax` | `chat`, `messages`, `responses` | `openai` | `https://api.minimax.io/v1` | `MINIMAX_API_KEY` |
| `mistral` | `chat`, `messages`, `responses`, `embeddings` | `openai` | `https://api.mistral.ai/v1` | `MISTRAL_API_KEY` |
| `modelscope` | `chat`, `messages`, `responses`, `images` | `openai` | `https://api-inference.modelscope.cn/v1` | `MODELSCOPE_API_KEY` |
| `moonshot` | `chat`, `messages`, `responses` | `openai` | `https://api.moonshot.ai/v1` | `MOONSHOT_API_KEY` |
| `morph` | `chat`, `messages`, `responses` | `openai` | `https://api.morphllm.com/v1` | `MORPH_API_KEY` |
| `nano-gpt` | `chat`, `messages`, `responses` | `openai` | `https://nano-gpt.com/api/v1` | `NANOGPT_API_KEY` |
| `nebius` | `chat`, `messages`, `responses`, `embeddings` | `openai` | `https://api.studio.nebius.ai/v1` | `NEBIUS_API_KEY` |
| `neosantara` | `chat`, `messages`, `responses` | `openai` | `https://api.neosantara.xyz/v1` | `NEOSANTARA_API_KEY` |
| `nlp_cloud` | `chat`, `messages`, `responses` | `openai` | `https://api.nlpcloud.io/v1/gpu` | `NLP_CLOUD_API_KEY` |
| `novita` | `chat`, `messages`, `responses` | `openai` | `https://api.novita.ai/v3/openai` | `NOVITA_API_KEY` |
| `nscale` | `chat`, `messages`, `responses` | `openai` | `https://inference.api.nscale.com/v1` | `NSCALE_API_KEY` |
| `nvidia_nim` | `chat`, `messages`, `responses` | `openai` | `https://integrate.api.nvidia.com/v1` | `NVIDIA_NIM_API_KEY` |
| `oci` | `chat`, `messages`, `responses` | `openai` | _set `OCI_API_BASE`_ | `OCI_API_KEY` |
| `ollama` | `chat`, `messages`, `responses`, `embeddings` | `openai` | `http://localhost:11434/v1` | `OLLAMA_API_KEY` |
| `ollama_chat` | `chat`, `messages`, `responses` | `openai` | `http://localhost:11434/v1` | `OLLAMA_API_KEY` |
| `oobabooga` | `chat`, `messages`, `responses`, `transcribe`, `speech`, `moderation`, `batches` | `openai` | _set `OOBABOOGA_API_BASE`_ | `OOBABOOGA_API_KEY` |
| `openai` | `chat`, `messages`, `responses`, `embeddings`, `images`, `transcribe`, `speech`, `moderation`, `batches` | `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `openai_like` | `embeddings` | `openai` | _set `OPENAI_LIKE_API_BASE`_ | `OPENAI_LIKE_API_KEY` |
| `openrouter` | `chat`, `messages`, `responses` | `openai` | `https://openrouter.ai/api/v1` | `OPENROUTER_API_KEY` or `OR_API_KEY` |
| `ovhcloud` | `chat`, `messages`, `responses` | `openai` | `https://oai.endpoints.kepler.ai.cloud.ovh.net/v1` | `OVHCLOUD_API_KEY` |
| `parasail` | `chat`, `messages`, `responses` | `openai` | `https://api.parasail.io/v1` | `PARASAIL_API_KEY` |
| `perplexity` | `chat`, `messages`, `responses` | `openai` | `https://api.perplexity.ai` | `PERPLEXITY_API_KEY` or `PERPLEXITYAI_API_KEY` |
| `petals` | `chat`, `messages`, `responses` | `openai` | _set `PETALS_API_BASE`_ | `PETALS_API_KEY` |
| `pinstripes` | `chat`, `messages`, `responses` | `openai` | `https://pinstripes.io/v1` | `PINSTRIPES_API_KEY` |
| `poe` | `chat`, `messages`, `responses` | `openai` | `https://api.poe.com/v1` | `POE_API_KEY` |
| `predibase` | `chat`, `messages`, `responses` | `openai` | `https://serving.app.predibase.com` | `PREDIBASE_API_KEY` |
| `publicai` | `chat`, `messages`, `responses` | `openai` | `https://api.publicai.co/v1` | `PUBLICAI_API_KEY` |
| `qwen_ai_platform` | `chat`, `messages`, `responses`, `embeddings`, `images`, `rerank` | `openai` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `QWEN_AI_PLATFORM_API_KEY` or `DASHSCOPE_API_KEY` |
| `qwencloud` | `chat`, `messages`, `responses`, `embeddings`, `images`, `rerank` | `openai` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `QWEN_AI_PLATFORM_API_KEY` or `DASHSCOPE_API_KEY` |
| `ragflow` | `chat`, `messages`, `responses` | `openai` | `http://localhost:9380/api/v1` | `RAGFLOW_API_KEY` |
| `recraft` | `images` | `openai` | `https://external.api.recraft.ai/v1` | `RECRAFT_API_KEY` |
| `replicate` | `chat`, `messages`, `responses` | `replicate` | `https://api.replicate.com/v1` | `REPLICATE_API_KEY` or `REPLICATE_API_TOKEN` |
| `sagemaker` | `chat`, `messages`, `responses`, `embeddings` | `bedrock` | _derived from region/project_ | `AWS_SECRET_ACCESS_KEY` |
| `sagemaker_chat` | `chat`, `messages`, `responses` | `bedrock` | _derived from region/project_ | `AWS_SECRET_ACCESS_KEY` |
| `sambanova` | `chat`, `messages`, `responses` | `openai` | `https://api.sambanova.ai/v1` | `SAMBANOVA_API_KEY` |
| `scaleway` | `chat`, `messages`, `responses` | `openai` | `https://api.scaleway.ai/v1` | `SCW_SECRET_KEY` |
| `snowflake` | `chat`, `messages`, `responses` | `openai` | _set `SNOWFLAKE_API_BASE`_ | `SNOWFLAKE_JWT` |
| `stability` | `images` | `image` | `https://api.stability.ai` | `STABILITY_API_KEY` |
| `synthetic` | `chat`, `messages`, `responses` | `openai` | `https://api.synthetic.new/openai/v1` | `SYNTHETIC_API_KEY` |
| `tencent` | `chat`, `messages`, `responses` | `openai` | `https://tokenhub-intl.tencentcloudmaas.com/v1` | `TENCENT_API_KEY` |
| `tensormesh` | `chat`, `messages`, `responses` | `openai` | `https://serverless.tensormesh.ai/v1` | `TENSORMESH_INFERENCE_API_KEY` |
| `text-completion-codestral` | `chat`, `messages`, `responses` | `openai` | `https://codestral.mistral.ai/v1` | `CODESTRAL_API_KEY` |
| `text-completion-inception` | `chat`, `messages`, `responses` | `openai` | `https://api.inceptionlabs.ai/v1` | `INCEPTION_API_KEY` |
| `text-completion-openai` | `chat`, `messages`, `responses`, `transcribe`, `speech`, `moderation`, `batches` | `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `together_ai` | `chat`, `messages`, `responses` | `openai` | `https://api.together.ai/v1` | `TOGETHER_API_KEY` or `TOGETHERAI_API_KEY` |
| `topaz` | `chat`, `messages`, `responses` | `openai` | `https://api.topazlabs.com/v1` | `TOPAZ_API_KEY` |
| `triton` | `chat`, `messages`, `responses` | `openai` | _set `TRITON_API_BASE`_ | `TRITON_API_KEY` |
| `v0` | `chat`, `messages`, `responses` | `openai` | `https://api.v0.dev/v1` | `V0_API_KEY` |
| `vercel_ai_gateway` | `chat`, `messages`, `responses` | `openai` | `https://ai-gateway.vercel.sh/v1` | `VERCEL_AI_GATEWAY_API_KEY` |
| `vertex_ai` | `chat`, `messages`, `responses`, `embeddings`, `images` | `gemini` | _derived from region/project_ | `VERTEX_AI_ACCESS_TOKEN` or `GOOGLE_ACCESS_TOKEN` |
| `vertex_ai_beta` | `chat`, `messages`, `responses` | `gemini` | _derived from region/project_ | `VERTEX_AI_ACCESS_TOKEN` or `GOOGLE_ACCESS_TOKEN` |
| `vllm` | `chat`, `messages`, `responses` | `openai` | _set `VLLM_API_BASE`_ | `VLLM_API_KEY` |
| `volcengine` | `chat`, `messages`, `responses` | `openai` | `https://ark.cn-beijing.volces.com/api/v3` | `VOLCENGINE_API_KEY` or `ARK_API_KEY` |
| `voyage` | `embeddings`, `rerank` | `openai` | `https://api.voyageai.com/v1` | `VOYAGE_API_KEY` or `VOYAGE_AI_API_KEY` |
| `wandb` | `chat`, `messages`, `responses` | `openai` | `https://api.inference.wandb.ai/v1` | `WANDB_API_KEY` |
| `watsonx` | `chat`, `messages`, `responses`, `embeddings` | `watsonx` | _set `WATSONX_API_BASE`_ | `WATSONX_API_KEY` or `WX_API_KEY` |
| `watsonx_text` | `chat`, `messages`, `responses` | `watsonx` | _set `WATSONX_TEXT_API_BASE`_ | `WATSONX_API_KEY` or `WX_API_KEY` |
| `xai` | `chat`, `messages`, `responses` | `openai` | `https://api.x.ai/v1` | `XAI_API_KEY` |
| `xiaomi_mimo` | `chat`, `messages`, `responses` | `openai` | `https://api.xiaomimimo.com/v1` | `XIAOMI_MIMO_API_KEY` |
| `xinference` | `embeddings` | `openai` | _set `XINFERENCE_API_BASE`_ | `XINFERENCE_API_KEY` |
| `zai` | `chat`, `messages`, `responses` | `openai` | `https://api.z.ai/api/paas/v4` | `ZAI_API_KEY` |

## Examples

### `text.lua`

```lua
-- one-shot completion, with the model named as "provider/model" so the same call reaches any provider
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = {
            { role = "system", content = "You answer in one short sentence." },
            { role = "user", content = "Why is the sky blue?" },
        },
        max_tokens = 200,
    })

    print(response.choices[1].message.content)
    print(string.format("tokens: %d in, %d out", response.usage.prompt_tokens, response.usage.completion_tokens))
end)
```

### `stream.lua`

```lua
-- streaming, where a handler receives openai-shaped chunks and the call still returns the assembled response
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = { { role = "user", content = "Count from one to ten in words." } },
        max_tokens = 200,
    }, function(chunk)
        local delta = chunk.choices[1].delta.content
        if delta then
            io.write(delta)
            io.flush()
        end
    end)

    print()
    print("finish reason: " .. tostring(response.choices[1].finish_reason))
end)
```

### `tools.lua`

```lua
-- tool calling, where the model asks for a function, the program answers, and the conversation continues
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local tools = {
    {
        type = "function",
        ["function"] = {
            name = "get_weather",
            description = "Current weather for a city",
            parameters = {
                type = "object",
                properties = { city = { type = "string" } },
                required = { "city" },
            },
        },
    },
}

async.run(function()
    local model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini"
    local messages = { { role = "user", content = "What is the weather in Lisbon?" } }

    local first = ai.completion({ model = model, messages = messages, tools = tools, max_tokens = 300 })
    local call = first.choices[1].message.tool_calls[1]
    print("model asked for: " .. call["function"].name .. " " .. call["function"].arguments)

    -- the assistant turn and the tool result both go back so the model can use the answer
    messages[#messages + 1] = first.choices[1].message
    messages[#messages + 1] = {
        role = "tool",
        tool_call_id = call.id,
        content = json.encode({ city = json.decode(call["function"].arguments).city, celsius = 21, sky = "clear" }),
    }

    local second = ai.completion({ model = model, messages = messages, tools = tools, max_tokens = 300 })
    print(second.choices[1].message.content)
end)
```

### `structured.lua`

```lua
-- structured output, where a json schema constrains the reply so it can be decoded directly
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local json = require("json")
local ai = require("ai")

local schema = {
    type = "object",
    properties = {
        city = { type = "string" },
        country = { type = "string" },
        population = { type = "integer" },
    },
    required = { "city", "country", "population" },
    additionalProperties = false,
}

async.run(function()
    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = { { role = "user", content = "Give me the facts for Lisbon." } },
        response_format = {
            type = "json_schema",
            json_schema = { name = "city_facts", schema = schema, strict = true },
        },
        max_tokens = 300,
    })

    local facts = json.decode(response.choices[1].message.content)
    print(string.format("%s, %s: %d people", facts.city, facts.country, facts.population))
end)
```

### `vision.lua`

```lua
-- multimodal input, where an image travels beside the text as an openai content part
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local crypto = require("crypto")
local fs = require("fs")
local ai = require("ai")

async.run(function()
    local path = arg[1]
    if not path then
        print("usage: varn vision.lua <image.png>")
        return
    end

    -- a data url keeps the image inline, which every provider in the registry accepts
    local bytes = fs.readFile(path):await()
    local dataUrl = "data:image/png;base64," .. crypto.base64Encode(bytes)

    local response = ai.completion({
        model = os.getenv("AI_MODEL") or "openai/gpt-4o-mini",
        messages = {
            {
                role = "user",
                content = {
                    { type = "text", text = "Describe this image in one sentence." },
                    { type = "image_url", image_url = { url = dataUrl } },
                },
            },
        },
        max_tokens = 300,
    })

    print(response.choices[1].message.content)
end)
```

### `image.lua`

```lua
-- image generation, written to disk through the saveImage helper
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local response = ai.imageGeneration({
        model = os.getenv("AI_IMAGE_MODEL") or "openai/gpt-image-1",
        prompt = "A lighthouse on a cliff at sunrise, watercolour",
        size = "1024x1024",
        n = 1,
    })

    ai.saveImage(response.data[1], "lighthouse.png")
    print("wrote lighthouse.png")
end)
```

### `audio.lua`

```lua
-- speech synthesis and recognition, round tripping one sentence through a provider and back
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local spoken = ai.speech({
        model = os.getenv("AI_SPEECH_MODEL") or "openai/gpt-4o-mini-tts",
        input = "Varn runs the same Lua everywhere.",
        voice = os.getenv("AI_VOICE") or "alloy",
    })

    ai.saveAudio(spoken, "speech.mp3")
    print("wrote speech.mp3")

    local heard = ai.transcription({
        model = os.getenv("AI_TRANSCRIBE_MODEL") or "openai/whisper-1",
        file = spoken,
        file_name = "speech.mp3",
    })

    print("heard back: " .. heard.text)
end)
```

## Tests

`ai/tests/mock_test.lua` and `ai/tests/adapters_test.lua` run every adapter against a local mock server, asserting both the body each one puts on the wire and the response it hands back, with no network and no API keys. The Bedrock signer is checked against the signing-key vector AWS publishes for Signature Version 4.

`ai/tests/live_test.lua` calls the real APIs, one tiny request per provider whose key is present, and is opt-in through `python3 run.py --ai-live`.
