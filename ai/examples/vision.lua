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
