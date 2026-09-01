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
