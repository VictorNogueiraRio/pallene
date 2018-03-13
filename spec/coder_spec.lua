local c_compiler = require "titan-compiler.c_compiler"
local util = require "titan-compiler.util"

local luabase = [[
local test = require "test"
local assert = require "luassert"
]]

local function run_coder(titan_code, test_script)
    local ok, errors = c_compiler.compile("test.titan", titan_code)
    assert(ok, errors[1])
    util.set_file_contents("test_script.lua", luabase .. test_script)
    local ok = os.execute("./lua/src/lua test_script.lua")
    assert.truthy(ok)
end

describe("Titan coder", function()
    after_each(function()
        os.execute("rm -f test.c")
        os.execute("rm -f test.so")
        os.execute("rm -f test_script.lua")
    end)

    it("compiles an empty program", function()
        run_coder("", "")
    end)

    it("compiles a program with constant globals", function()
        run_coder([[
            x1: integer = 42
            x2: float = 10.5
            x3: boolean = true
            local x4: integer = 13
        ]], [[
            assert.equals(42,   test.x1)
            assert.equals(10.5, test.x2)
            assert.equals(true, test.x3)
            assert.equals(nil,  test.x4)
        ]])
    end)
end)
