-- unified ai client over the native http client for text, images, and audio across openai, anthropic claude, google gemini, and every openai-compatible provider, where each call yields on the event loop so the whole lifecycle must run inside an async coroutine (async.run/async.spawn)
local crypto = require("crypto")
local fs = require("fs")

local ai = {}

-- per-provider base url, wire adapter, and the environment variable consulted when no apiKey is passed
local providers = {
    openai = { baseUrl = "https://api.openai.com/v1", adapter = "openai", envKey = "OPENAI_API_KEY" },
    grok = { baseUrl = "https://api.x.ai/v1", adapter = "openai", envKey = "XAI_API_KEY" },
    deepseek = { baseUrl = "https://api.deepseek.com", adapter = "openai", envKey = "DEEPSEEK_API_KEY" },
    moonshot = { baseUrl = "https://api.moonshot.ai/v1", adapter = "openai", envKey = "MOONSHOT_API_KEY" },
    kimi = { baseUrl = "https://api.moonshot.ai/v1", adapter = "openai", envKey = "MOONSHOT_API_KEY" },
    groq = { baseUrl = "https://api.groq.com/openai/v1", adapter = "openai", envKey = "GROQ_API_KEY" },
    mistral = { baseUrl = "https://api.mistral.ai/v1", adapter = "openai", envKey = "MISTRAL_API_KEY" },
    together = { baseUrl = "https://api.together.xyz/v1", adapter = "openai", envKey = "TOGETHER_API_KEY" },
    openrouter = { baseUrl = "https://openrouter.ai/api/v1", adapter = "openai", envKey = "OPENROUTER_API_KEY" },
    ollama = { baseUrl = "http://localhost:11434/v1", adapter = "openai" },
    anthropic = { baseUrl = "https://api.anthropic.com", adapter = "anthropic", envKey = "ANTHROPIC_API_KEY" },
    claude = { baseUrl = "https://api.anthropic.com", adapter = "anthropic", envKey = "ANTHROPIC_API_KEY" },
    gemini = { baseUrl = "https://generativelanguage.googleapis.com", adapter = "gemini", envKey = "GEMINI_API_KEY" },
    google = { baseUrl = "https://generativelanguage.googleapis.com", adapter = "gemini", envKey = "GEMINI_API_KEY" },
}

-- adapters are required lazily so loading ai never forces an adapter a program does not use
local adapterLoaders = {
    openai = function()
        return require("ai.adapters.openai")
    end,
    anthropic = function()
        return require("ai.adapters.anthropic")
    end,
    gemini = function()
        return require("ai.adapters.gemini")
    end,
}

local Client = {}
Client.__index = Client

function Client:generate(request)
    return self.adapter.generate(self, request)
end

function Client:stream(request, onEvent)
    return self.adapter.stream(self, request, onEvent)
end

function Client:image(request)
    if not self.adapter.image then
        error("ai: provider " .. self.provider .. " does not support image generation", 0)
    end

    return self.adapter.image(self, request)
end

function Client:embed(request)
    if not self.adapter.embed then
        error("ai: provider " .. self.provider .. " does not support embeddings", 0)
    end

    return self.adapter.embed(self, request)
end

function ai.client(config)
    local profile = providers[config.provider]
    if not profile then
        error("ai: unknown provider " .. tostring(config.provider), 0)
    end

    local loader = adapterLoaders[profile.adapter]

    return setmetatable({
        provider = config.provider,
        apiKey = config.apiKey or (profile.envKey and os.getenv(profile.envKey)),
        model = config.model,
        imageModel = config.imageModel,
        embedModel = config.embedModel,
        baseUrl = config.baseUrl or profile.baseUrl,
        headers = config.headers,
        timeoutSeconds = config.timeoutSeconds,
        adapter = loader(),
    }, Client)
end

local AudioClient = {}
AudioClient.__index = AudioClient

function AudioClient:tts(request)
    return self.adapter.tts(self, request)
end

function AudioClient:ttsStream(request, onChunk)
    return self.adapter.ttsStream(self, request, onChunk)
end

function AudioClient:stt(request)
    return self.adapter.stt(self, request)
end

function AudioClient:voices()
    return self.adapter.voices(self)
end

function AudioClient:soundEffect(request)
    return self.adapter.soundEffect(self, request)
end

function ai.audio(config)
    config = config or {}
    local provider = config.provider or "elevenlabs"
    if provider ~= "elevenlabs" then
        error("ai.audio: unsupported provider " .. tostring(provider), 0)
    end

    return setmetatable({
        provider = provider,
        apiKey = config.apiKey or os.getenv("ELEVENLABS_API_KEY"),
        baseUrl = config.baseUrl or "https://api.elevenlabs.io",
        timeoutSeconds = config.timeoutSeconds,
        adapter = require("ai.adapters.elevenlabs"),
    }, AudioClient)
end

-- writes an image returned by image() to a file, decoding its base64 or downloading its url
function ai.saveImage(image, path)
    assert(image, "ai.saveImage: no image given")

    local bytes
    if image.base64 then
        bytes = crypto.base64Decode(image.base64)
    elseif image.url then
        local response, err = require("http").client.get(image.url):await()
        if err then
            error("ai.saveImage: download failed: " .. tostring(err), 0)
        end
        if not response.ok then
            error("ai.saveImage: download failed with http " .. response.status, 0)
        end
        bytes = response.body
    else
        error("ai.saveImage: image has neither base64 nor url", 0)
    end

    fs.writeFile(path, bytes):await()
end

-- writes raw audio bytes returned by tts() or soundEffect() to a file
function ai.saveAudio(bytes, path)
    fs.writeFile(path, bytes):await()
end

return ai
