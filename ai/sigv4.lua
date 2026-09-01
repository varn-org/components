-- aws signature version 4 for the request shape the bedrock adapter sends, a signed json post with no query string
local crypto = require("crypto")

local sigv4 = {}

local algorithm = "AWS4-HMAC-SHA256"

-- the signing key is derived by chaining hmacs over the date, region, service and the terminator
function sigv4.signingKey(secretKey, date, region, service)
    local key = crypto.hmac("SHA256", "AWS4" .. secretKey, date, "raw")
    key = crypto.hmac("SHA256", key, region, "raw")
    key = crypto.hmac("SHA256", key, service, "raw")
    return crypto.hmac("SHA256", key, "aws4_request", "raw")
end

-- formats the instant the way the protocol wants it, as basic iso8601 in utc
function sigv4.timestamp(now)
    now = now or os.date("!*t")
    return string.format("%04d%02d%02dT%02d%02d%02dZ", now.year, now.month, now.day, now.hour, now.min, now.sec)
end

-- returns the headers a signed request must carry, including the authorization header itself
function sigv4.headers(options)
    local stamp = options.timestamp or sigv4.timestamp()
    local date = stamp:sub(1, 8)
    local payloadHash = crypto.digest("SHA256", options.body, "hex")

    local headers = {
        ["content-type"] = options.contentType or "application/json",
        ["host"] = options.host,
        ["x-amz-content-sha256"] = payloadHash,
        ["x-amz-date"] = stamp,
    }
    if options.sessionToken then
        headers["x-amz-security-token"] = options.sessionToken
    end

    local names = {}
    for name in pairs(headers) do
        names[#names + 1] = name
    end
    table.sort(names)

    local canonicalHeaders = {}
    for _, name in ipairs(names) do
        canonicalHeaders[#canonicalHeaders + 1] = name .. ":" .. headers[name] .. "\n"
    end
    local signedHeaders = table.concat(names, ";")

    local canonicalRequest = table.concat({
        options.method,
        options.path,
        options.query or "",
        table.concat(canonicalHeaders),
        signedHeaders,
        payloadHash,
    }, "\n")

    local scope = string.format("%s/%s/%s/aws4_request", date, options.region, options.service)
    local stringToSign = table.concat({
        algorithm,
        stamp,
        scope,
        crypto.digest("SHA256", canonicalRequest, "hex"),
    }, "\n")

    local key = sigv4.signingKey(options.secretKey, date, options.region, options.service)
    local signature = crypto.hmac("SHA256", key, stringToSign, "hex")

    headers["Authorization"] = string.format(
        "%s Credential=%s/%s, SignedHeaders=%s, Signature=%s",
        algorithm,
        options.accessKey,
        scope,
        signedHeaders,
        signature
    )

    return headers
end

return sigv4
