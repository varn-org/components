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
