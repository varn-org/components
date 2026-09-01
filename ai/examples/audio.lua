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
