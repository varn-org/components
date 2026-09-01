-- the specialised endpoints each provider serves beyond chat, so a call a provider cannot answer raises here instead of reaching the network
local capabilities = {}

-- chat is served wherever the adapter implements a completion, and the message and response surfaces are alternative shapes over that one capability, so only these need declaring
local declared = {
    ["aiml"] = { "embedding", "imageGeneration" },
    ["anthropic"] = { "batch" },
    ["anthropic_text"] = { "batch" },
    ["assemblyai"] = { "transcription" },
    ["azure"] = { "embedding", "imageGeneration", "transcription", "speech", "moderation", "batch" },
    ["azure_ai"] = { "embedding", "imageGeneration", "transcription", "speech", "moderation", "batch" },
    ["azure_text"] = { "transcription", "speech", "moderation", "batch" },
    ["bedrock"] = { "embedding", "rerank" },
    ["cohere"] = { "embedding", "rerank" },
    ["cometapi"] = { "embedding" },
    ["custom_openai"] = { "transcription", "speech", "moderation", "batch" },
    ["dashscope"] = { "embedding", "rerank" },
    ["deepgram"] = { "transcription" },
    ["elevenlabs"] = { "transcription", "speech" },
    ["fal_ai"] = { "imageGeneration" },
    ["github_copilot"] = { "embedding" },
    ["huggingface"] = { "embedding", "rerank" },
    ["infinity"] = { "embedding" },
    ["jina_ai"] = { "embedding", "rerank" },
    ["litellm_proxy"] = { "embedding", "imageGeneration" },
    ["mistral"] = { "embedding" },
    ["modelscope"] = { "imageGeneration" },
    ["nebius"] = { "embedding" },
    ["ollama"] = { "embedding" },
    ["oobabooga"] = { "transcription", "speech", "moderation", "batch" },
    ["openai"] = { "embedding", "imageGeneration", "transcription", "speech", "moderation", "batch" },
    ["openai_like"] = { "embedding" },
    ["qwen_ai_platform"] = { "embedding", "imageGeneration", "rerank" },
    ["qwencloud"] = { "embedding", "imageGeneration", "rerank" },
    ["recraft"] = { "imageGeneration" },
    ["sagemaker"] = { "embedding" },
    ["text-completion-openai"] = { "transcription", "speech", "moderation", "batch" },
    ["vertex_ai"] = { "embedding", "imageGeneration" },
    ["voyage"] = { "embedding", "rerank" },
    ["watsonx"] = { "embedding" },
    ["xinference"] = { "embedding" },
}

local served = {}

for slug, endpoints in pairs(declared) do
    served[slug] = {}
    for _, endpoint in ipairs(endpoints) do
        served[slug][endpoint] = true
    end
end

function capabilities.serves(slug, endpoint)
    local set = served[slug]
    return set ~= nil and set[endpoint] == true
end

return capabilities
