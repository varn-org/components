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
