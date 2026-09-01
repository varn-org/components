-- image generation, saving the result to a file with ai.saveImage
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local async = require("async")
local ai = require("ai")

async.run(function()
    local client = ai.client({
        provider = os.getenv("AI_PROVIDER") or "openai",
        imageModel = os.getenv("AI_IMAGE_MODEL") or "gpt-image-1",
    })

    local result = client:image({
        prompt = "a calm watercolor landscape of green hills at sunrise",
        size = "1024x1024",
    })

    local path = os.getenv("AI_IMAGE_OUT") or "image.png"
    ai.saveImage(result.images[1], path)
    print("saved", path)
end)
