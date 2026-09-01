-- a small suite showing describe/it/expect and the pass/fail summary the runner prints
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local test = require("test")
local describe, it, expect = test.describe, test.it, test.expect

local function add(a, b)
    return a + b
end

describe("math", function()
    it("adds two numbers", function()
        expect(add(2, 3)):toBe(5)
    end)

    it("is commutative", function()
        expect(add(2, 3)):toBe(add(3, 2))
    end)
end)

describe("tables", function()
    it("compares by content", function()
        expect({ a = 1, b = { 2, 3 } }):toEqual({ a = 1, b = { 2, 3 } })
    end)
end)

describe("errors", function()
    it("detects a throw", function()
        expect(function()
            error("boom")
        end):toThrow()
    end)

    it("treats a value as truthy", function()
        expect("present"):toBeTruthy()
        expect(nil):toBeFalsy()
    end)
end)

test.run()
