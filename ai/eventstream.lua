-- decoder for the aws binary event stream, whose frames carry their headers and a json payload behind a fixed prelude
local eventstream = {}

local preludeBytes = 12
local trailerBytes = 4

-- the protocol caps a frame well below this, so a larger declared length is a corrupt stream rather than a frame still arriving
local maxFrameBytes = 24 * 1024 * 1024

local function readUint32(buffer, offset)
    local a, b, c, d = buffer:byte(offset, offset + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function readUint16(buffer, offset)
    local a, b = buffer:byte(offset, offset + 1)
    return a * 256 + b
end

-- header values are typed, and only the string type carries anything this decoder needs
local function readHeaders(buffer, offset, length)
    local headers = {}
    local cursor = offset
    local limit = offset + length

    while cursor < limit do
        local nameLength = buffer:byte(cursor)
        local name = buffer:sub(cursor + 1, cursor + nameLength)
        cursor = cursor + 1 + nameLength

        local valueType = buffer:byte(cursor)
        cursor = cursor + 1

        if valueType == 7 or valueType == 6 then
            local valueLength = readUint16(buffer, cursor)
            headers[name] = buffer:sub(cursor + 2, cursor + 1 + valueLength)
            cursor = cursor + 2 + valueLength
        elseif valueType == 0 or valueType == 1 then
            headers[name] = valueType == 0
        elseif valueType == 2 then
            cursor = cursor + 1
        elseif valueType == 3 then
            cursor = cursor + 2
        elseif valueType == 4 then
            cursor = cursor + 4
        elseif valueType == 5 or valueType == 8 then
            cursor = cursor + 8
        elseif valueType == 9 then
            cursor = cursor + 16
        else
            error("ai: unknown event stream header type " .. tostring(valueType), 0)
        end
    end

    return headers
end

-- consumes every complete frame in the buffer, calling handler(headers, payload), and returns the bytes left over
function eventstream.consume(buffer, handler)
    while #buffer >= preludeBytes do
        local total = readUint32(buffer, 1)
        if total < preludeBytes + trailerBytes or total > maxFrameBytes then
            error("ai: event stream frame declares an impossible length", 0)
        end

        if #buffer < total then
            break
        end

        -- the header block is sized by the stream itself, so it is checked against the frame before anything reads with it
        local headerLength = readUint32(buffer, 5)
        if headerLength > total - preludeBytes - trailerBytes then
            error("ai: event stream frame declares headers larger than itself", 0)
        end

        local headers = readHeaders(buffer, preludeBytes + 1, headerLength)
        local payload = buffer:sub(preludeBytes + headerLength + 1, total - trailerBytes)

        handler(headers, payload)
        buffer = buffer:sub(total + 1)
    end

    return buffer
end

return eventstream
