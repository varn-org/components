-- the test runner's own suite written with the runner, exercising every matcher and verifying they fail on wrong input before running the suite
local dir = arg[0]:match("^(.*)[/\\]") or "."
package.path = ("%s/../../?.lua;%s/../../?/init.lua;"):format(dir, dir) .. package.path

local test = require("test")
local describe, it, expect = test.describe, test.it, test.expect

describe("toBe", function()
    it("passes on identical primitives", function()
        expect(42):toBe(42)
        expect("x"):toBe("x")
    end)

    it("fails on different values", function()
        expect(function()
            expect(1):toBe(2)
        end):toThrow()
    end)
end)

describe("toEqual", function()
    it("passes on deeply equal tables", function()
        expect({ a = 1, nested = { 1, 2, 3 } }):toEqual({ a = 1, nested = { 1, 2, 3 } })
    end)

    it("fails on a differing table", function()
        expect(function()
            expect({ a = 1 }):toEqual({ a = 2 })
        end):toThrow()
    end)

    it("fails on an extra key", function()
        expect(function()
            expect({ a = 1, b = 2 }):toEqual({ a = 1 })
        end):toThrow()
    end)
end)

describe("truthiness", function()
    it("toBeTruthy passes on a value", function()
        expect(0):toBeTruthy()
        expect(""):toBeTruthy()
    end)

    it("toBeTruthy fails on nil and false", function()
        expect(function()
            expect(nil):toBeTruthy()
        end):toThrow()
        expect(function()
            expect(false):toBeTruthy()
        end):toThrow()
    end)

    it("toBeFalsy passes on nil and false", function()
        expect(nil):toBeFalsy()
        expect(false):toBeFalsy()
    end)
end)

describe("toThrow", function()
    it("passes when the function raises", function()
        expect(function()
            error("expected")
        end):toThrow()
    end)

    it("fails when the function does not raise", function()
        expect(function()
            expect(function() end):toThrow()
        end):toThrow()
    end)
end)

test.run()
