-- loads a small .env file written next to this example and reads typed values out of it
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local env = require("env")

local envPath = dir .. "/app.env"

-- write a throwaway .env to demonstrate loading since a real app ships its own
local file = assert(io.open(envPath, "w"))
file:write("# application settings\n")
file:write("APP_NAME=varn-demo\n")
file:write("APP_PORT=8080\n")
file:write('APP_DEBUG="true"\n')
file:write("export APP_REGION=eu-west-1\n")
file:close()

env.load(envPath)

print("name:", env.get("APP_NAME"))
print("port:", env.int("APP_PORT"))
print("debug:", env.bool("APP_DEBUG", false))
print("region:", env.require("APP_REGION"))
print("missing with default:", env.get("APP_TIMEOUT", "30s"))

os.remove(envPath)

print("env basic ok")
