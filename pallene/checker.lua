-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local ast = require "pallene.ast"
local builtins = require "pallene.builtins"
local symtab = require "pallene.symtab"
local types = require "pallene.types"
local typedecl = require "pallene.typedecl"
local util = require "pallene.util"

--
-- This file is responsible for type-checking a Pallene module and for resolving the scope of all
-- identifiers. The result is a modified AST that is annotated with this information:
--
--   * _type: A types.T in the following kinds of nodes
--      - ast.Exp
--      - ast.Var
--      - ast.Decl
--      - ast.Toplevel.Record
--
--   * _name: In ast.Var.Name nodes, a checker.Name that points to the matching declaration.
--
-- We also make some adjustments to the AST:
--
--   * We convert qualified identifiers such as `io.write` from ast.Var.Dot to a flat ast.Var.Name.
--   * We insert explicit ast.Exp.Cast nodes where there is an implicit upcast or downcast.
--   * We insert ast.Exp.ExtraRet nodes to represent additional return values from functions.
--   * We insert an explicit call to tofloat in some arithmetic operations. For example int + float.
--   * We add an explicit +1 or +1.0 step in numeric for loops without a loop step.
--
-- In order for these transformations to work it is important to always use the return value from
-- the check_exp and check_var functions. For example, instead of just `check_exp(foo.exp)` you
-- should write `foo.exp = check_exp(foo.exp)`.
--

local checker = {}

local Checker = util.Class()

-- Type-check a Pallene module
-- On success, returns the typechecked module for the program
-- On failure, returns false and a list of compilation errors
function checker.check(prog_ast)
    local co = coroutine.create(function()
        return Checker.new():check_program(prog_ast)
    end)
    local ok, value = coroutine.resume(co)
    if ok then
        if coroutine.status(co) == "dead" then
            prog_ast = value
            return prog_ast, {}
        else
            local compiler_error_msg = value
            return false, { compiler_error_msg }
        end
    else
        local unhandled_exception_msg = value
        local stack_trace = debug.traceback(co)
        error(unhandled_exception_msg .. "\n" .. stack_trace)
    end
end

-- Usually if an error is produced with `assert()` or `error()` then it is
-- a compiler bug. User-facing errors such as syntax errors and
-- type checking errors are reported in a different way. The actual
-- method employed is kind of tricky. Since Lua does not have a clean
-- try-catch functionality we use coroutines to do that job.
-- You can see this in the `checker.check()` function but you do
-- not need to know how it works. You just need to know that calling
-- `scope_error()` or `type_error()` will exit the type checking routine
-- and report a Pallene compilation error.
local function checker_error(loc, fmt, ...)
    local error_message = loc:format_error(fmt, ...)
    coroutine.yield(error_message)
end

local function scope_error(loc, fmt, ...)
    return checker_error(loc, ("scope error: " .. fmt), ...)
end

local function type_error(loc, fmt, ...)
    return checker_error(loc, ("type error: " .. fmt), ...)
end

local function check_type_is_condition(exp, fmt, ...)
    local typ = exp._type
    if typ._tag ~= "types.T.Boolean" and typ._tag ~= "types.T.Any" then
        type_error(exp.loc,
            "expression passed to %s has type %s. Expected boolean or any.",
            string.format(fmt, ...),
            types.tostring(typ))
    end
end


--
--
--

function Checker:init()
    self.symbol_table = symtab.new() -- string => checker.Name
    self.ret_types_stack = {}        -- stack of types.T
    return self
end


--
-- Symbol table
--

local function declare_type(type_name, cons)
    typedecl.declare(checker, "checker", type_name, cons)
end

declare_type("Name", {
    Type     = { "typ" },
    Local    = { "decl" },
    Global   = { "decl" },
    Function = { "decl" },
    Builtin  = { "name" },
    Module   = { "name", "is_main_mod" }
})

function Checker:add_type(name, typ)
    assert(typedecl.match_tag(typ._tag, "types.T"))
    self.symbol_table:add_symbol(name, checker.Name.Type(typ))
end

function Checker:add_local(decl)
    assert(decl._tag == "ast.Decl.Decl")
    self.symbol_table:add_symbol(decl.name, checker.Name.Local(decl))
end

function Checker:add_global(decl)
    assert(decl._tag == "ast.Decl.Decl")
    local name = decl._modname and (decl._modname .. '.' .. decl.name) or decl.name
    self.symbol_table:add_symbol(name, checker.Name.Global(decl))
end

function Checker:add_function(decl)
    assert(decl._tag == "ast.Decl.Decl")
    local name = decl._modname and (decl._modname .. '.' .. decl.name) or decl.name
    self.symbol_table:add_symbol(name, checker.Name.Function(decl))
end

function Checker:add_builtin(name, id)
    assert(type(name) == "string")
    self.symbol_table:add_symbol(name, checker.Name.Builtin(id))
end

function Checker:add_module(name, is_main_mod)
    assert(type(name) == "string")
    self.symbol_table:add_symbol(name, checker.Name.Module(name, is_main_mod))
end

local function check_module_field_duplicate(mod_cname, decl)
    local old_loc = mod_cname.fields[decl.name] and mod_cname.fields[decl.name].decl.loc
    if old_loc then
        scope_error(decl.loc,
          "duplicate module field '%s', previous one at line %d",
          decl.name, old_loc.line)
    end
end

--
--
--

function Checker:from_ast_type(ast_typ)
    local tag = ast_typ._tag
    if     tag == "ast.Type.Nil" then
        return types.T.Nil()

    elseif tag == "ast.Type.Module" then
        return types.T.Module()

    elseif tag == "ast.Type.Name" then
        local name = ast_typ.name
        local cname = self.symbol_table:find_symbol(name)
        if not cname then
            scope_error(ast_typ.loc,  "type '%s' is not declared", name)
        elseif cname._tag == "checker.Name.Type" then
            return cname.typ
        elseif cname._tag == "checker.Name.Module" and cname.name == "string" then
            -- Currently the string type appears in the scope as a module because of functions like
            -- string.char and string.sub. In the future we might want to consider extending this
            -- feature to other modules that also count as types.
            return types.T.String()
        end
        type_error(ast_typ.loc, "'%s' isn't a type", name)

    elseif tag == "ast.Type.Array" then
        local subtype = self:from_ast_type(ast_typ.subtype)
        return types.T.Array(subtype)

    elseif tag == "ast.Type.Table" then
        local fields = {}
        for _, field in ipairs(ast_typ.fields) do
            if fields[field.name] then
                type_error(ast_typ.loc, "duplicate field '%s' in table", field.name)
            end
            fields[field.name] = self:from_ast_type(field.type)
        end
        return types.T.Table(fields)

    elseif tag == "ast.Type.Function" then
        local p_types = {}
        for _, p_type in ipairs(ast_typ.arg_types) do
            table.insert(p_types, self:from_ast_type(p_type))
        end
        local ret_types = {}
        for _, ret_type in ipairs(ast_typ.ret_types) do
            table.insert(ret_types, self:from_ast_type(ret_type))
        end
        return types.T.Function(p_types, ret_types)

    else
        typedecl.tag_error(tag)
    end
end

local letrec_groups = {
    ["ast.Toplevel.Var"]       = "Var",
    ["ast.Toplevel.Func"]      = "Func",
    ["ast.Toplevel.Typealias"] = "Type",
    ["ast.Toplevel.Record"]    = "Type",
    ["ast.Toplevel.Stat"]      = "Stat",
}

function Checker:check_program(prog_ast)
    assert(prog_ast._tag == "ast.Program.Program")
    local tls = prog_ast.tls

    -- Add most primitive types to the symbol table
    self:add_type("any",     types.T.Any())
    self:add_type("boolean", types.T.Boolean())
    self:add_type("float",   types.T.Float())
    self:add_type("integer", types.T.Integer())
    --self:add_type("string",  types.T.String()) -- treated as a "module" because of string.char

    -- Add builtins to symbol table. The order does not matter because they are distinct.
    for name, _ in pairs(builtins.functions) do
        self:add_builtin(name, name)
    end
    for name in pairs(builtins.modules) do
        self:add_module(name)
    end

    -- Group mutually-recursive definitions
    local tl_groups = {}
    do
        local i = 1
        local N = #tls
        while i <= N do
            local node1 = tls[i]
            local tag1  = node1._tag
            assert(letrec_groups[tag1])

            local group = { node1 }
            local j = i + 1
            while j <= N do
                local node2 = tls[j]
                local tag2  = node2._tag
                assert(letrec_groups[tag2])

                if letrec_groups[tag1] ~= letrec_groups[tag2] then
                    break
                end

                table.insert(group, node2)
                j = j + 1
            end
            table.insert(tl_groups, group)
            i = j
        end
    end

    -- Check toplevel
    for _, tl_group in ipairs(tl_groups) do
        local group_kind = letrec_groups[tl_group[1]._tag]

        if     group_kind == "Import" then
            local loc = tl_group[1].loc
            type_error(loc, "modules are not implemented yet")

        elseif group_kind == "Type" then

            -- TODO: Implement recursive and mutually recursive types
            for _, tl_node in ipairs(tl_group) do
                local tag = tl_node._tag
                if     tag == "ast.Toplevel.Typealias" then
                    self:add_type(tl_node.name, self:from_ast_type(tl_node.type))

                elseif tag == "ast.Toplevel.Record" then
                    local field_names = {}
                    local field_types = {}
                    for _, field_decl in ipairs(tl_node.field_decls) do
                        local field_name = field_decl.name
                        table.insert(field_names, field_name)
                        field_types[field_name] = self:from_ast_type(field_decl.type)
                    end

                    local typ = types.T.Record(tl_node.name, field_names, field_types)
                    tl_node._type = typ
                    self:add_type(tl_node.name, typ)

                else
                    typedecl.tag_error(tag)
                end
            end

        elseif group_kind == "Stat" then
            -- skip

        else
            error("impossible")
        end
    end

    local total_nodes = #tls
    if total_nodes == 0 then
        return prog_ast
    end

    for i = 1, total_nodes - 1 do
        local stat = tls[i].stat
        if stat then
            if stat._tag == "ast.Stat.Return" then
                type_error(stat.loc, "Only the last toplevel node can be a return statement")
            end
            tls[i].stat = self:check_stat(stat, true)
        end
    end

    local last_toplevel_node = prog_ast.tls[total_nodes]
    local last_stat = last_toplevel_node.stat
    if last_toplevel_node._tag ~= "ast.Toplevel.Stat" or
       not last_stat or last_stat._tag ~= "ast.Stat.Return" then
        type_error(last_stat.loc, "Last Toplevel element must be a return statement")
    end

    local ret_types = {}
    ret_types[1] = types.T.Module()
    table.insert(self.ret_types_stack, ret_types)
    self:check_stat(last_stat, true)
    table.remove(self.ret_types_stack)
    table.remove(prog_ast.tls)

    return prog_ast
end

function Checker:mod_assign_rhs_type(exp)
    local typ = exp._type
    local tag = typ._tag
    if     tag == "types.T.Record" or
           tag == "types.T.Array" or
           tag == "types.T.Module" or
           tag == "types.T.Function" or
           tag == "types.T.Any" or
           tag == "types.T.Void"
    then
        type_error(exp.loc,
          string.format("Can't assign module field to %s", types.tostring(typ)))
    end
end
-- If the last expression in @rhs is a function call that returns multiple values, add ExtraRet
-- nodes to the end of the list.
function Checker:expand_function_returns(rhs)
    local last = rhs[#rhs]
    if  last and (last._tag == "ast.Exp.CallFunc" or last._tag == "ast.Exp.CallMethod") then
        last = self:check_exp_synthesize(last)
        rhs[#rhs] = last
        for i = 2, #last._types do
            table.insert(rhs, ast.Exp.ExtraRet(last.loc, last, i))
        end
    end
end

function Checker:check_stat(stat, istoplevel)
    local tag = stat._tag
    if     tag == "ast.Stat.Decl" then

        self:expand_function_returns(stat.exps)

        for i, decl in ipairs(stat.decls) do
            stat.exps[i] =
                self:check_initializer_exp(
                    decl, stat.exps[i],
                    "declaration of local variable %s", decl.name)
        end

        for i, decl in ipairs(stat.decls) do
            local typ = decl._type
            if decl._modname then
                self:mod_assign_rhs_type(stat.exps[i])
            end
            local is_main_mod = typ._tag == "types.T.Module"
            if istoplevel then
                if is_main_mod then
                    self:add_module(decl.name, true)
                else
                    self:add_global(decl)
                end
            else
                self:add_local(decl)
            end
            if is_main_mod then
                if self.mod_name then
                    type_error(decl.loc,
                      "There can only be one module variable per program")
                end
                self.mod_name = decl.name
            end
        end

    elseif tag == "ast.Stat.Block" then
        self.symbol_table:with_block(function()
            for _, inner_stat in ipairs(stat.stats) do
                self:check_stat(inner_stat, false)
            end
        end)

    elseif tag == "ast.Stat.While" then
        stat.condition = self:check_exp_synthesize(stat.condition)
        check_type_is_condition(stat.condition, "while loop condition")
        self:check_stat(stat.block, false)

    elseif tag == "ast.Stat.Repeat" then
        assert(stat.block._tag == "ast.Stat.Block")
        self.symbol_table:with_block(function()
            for _, inner_stat in ipairs(stat.block.stats) do
                self:check_stat(inner_stat, false)
            end
            stat.condition = self:check_exp_synthesize(stat.condition)
            check_type_is_condition(stat.condition, "repeat-until loop condition")
        end)

    elseif tag == "ast.Stat.ForNum" then

        stat.start =
            self:check_initializer_exp(
                stat.decl, stat.start,
                "numeric for-loop initializer")

        local loop_type = stat.decl._type

        if  loop_type._tag ~= "types.T.Integer" and
            loop_type._tag ~= "types.T.Float"
        then
            type_error(stat.decl.loc,
                "expected integer or float but found %s in for-loop control variable '%s'",
                types.tostring(loop_type), stat.decl.name)
        end

        if not stat.step then
            if     loop_type._tag == "types.T.Integer" then
                stat.step = ast.Exp.Integer(stat.limit.loc, 1)
            elseif loop_type._tag == "types.T.Float" then
                stat.step = ast.Exp.Float(stat.limit.loc, 1.0)
            else
                typedecl.tag_error(loop_type._tag, "loop type is not a number.")
            end
        end

        stat.limit = self:check_exp_verify(stat.limit, loop_type, "numeric for-loop limit")
        stat.step = self:check_exp_verify(stat.step, loop_type, "numeric for-loop step")

        self.symbol_table:with_block(function()
            self:add_local(stat.decl)
            self:check_stat(stat.block, false)
        end)
    elseif tag == "ast.Stat.ForIn" then
        local rhs = stat.exps
        self:expand_function_returns(rhs)

        if not rhs[1] then
            type_error(stat.loc, "missing right hand side of for-in loop")
        end

        if not rhs[2] then
            type_error(rhs[1].loc, "missing state variable in for-in loop")
        end

        if not rhs[3] then
            type_error(rhs[1].loc, "missing control variable in for-in loop")
        end

        local expected_ret_types = {}
        for _ = 1, #stat.decls do
            table.insert(expected_ret_types, types.T.Any())
        end

        local itertype = types.T.Function({ types.T.Any(), types.T.Any() }, expected_ret_types)
        rhs[1] = self:check_exp_synthesize(rhs[1])
        local iteratorfn = rhs[1]

        if not types.equals(iteratorfn._type, itertype) then
            type_error(iteratorfn.loc, "expected %s but found %s in loop iterator",
                types.tostring(itertype), types.tostring(iteratorfn._type))
        end

        rhs[2] = self:check_exp_synthesize(rhs[2])
        rhs[3] = self:check_exp_synthesize(rhs[3])

        if rhs[2]._type._tag ~= "types.T.Any" then
            type_error(rhs[2].loc, "expected any but found %s in loop state value",
                types.tostring(rhs[2]._type))
        end

        if rhs[3]._type._tag ~= "types.T.Any" then
            type_error(rhs[2].loc, "expected any but found %s in loop control value",
            types.tostring(rhs[3]._type))
        end

        if #stat.decls ~= #iteratorfn._type.ret_types then
            type_error(stat.decls[1].loc, "expected %d values, but function returns %d",
                       #stat.decls, #iteratorfn._type.ret_types)
        end

        self.symbol_table:with_block(function()
            local ret_types = iteratorfn._type.ret_types
            for i, decl in ipairs(stat.decls) do
                if decl.type then
                    decl._type = self:from_ast_type(decl.type)
                    if not types.consistent(decl._type, ret_types[i]) then
                        type_error(decl.loc, "expected value of type %s, but iterator returns %s",
                                   types.tostring(decl._type), types.tostring(ret_types[i]))
                    end
                else
                    stat.decls[i]._type = ret_types[i]
                end
                self:add_local(stat.decls[i])
            end
            self:check_stat(stat.block, false)
        end)

    elseif tag == "ast.Stat.Assign" then
        self:expand_function_returns(stat.exps)

        for i = 1, #stat.vars do
            if stat.vars[i]._tag == "ast.Var.Dot" then
                local top_var = stat.vars[i].exp.var
                local mod_cname = self.symbol_table:find_symbol(top_var.name)
                if mod_cname and mod_cname._tag == "checker.Name.Module" then
                    if #stat.vars > 1 then
                        type_error(stat.loc,
                          "Module assignment can only have one element at the lhs")
                    end
                    local loc, name = stat.loc, stat.vars[i].name
                    local decl = ast.Decl.Decl(loc, name, nil)
                    decl._modname = top_var.name
                    local newstat = ast.Stat.Decl(loc, {decl}, stat.exps)
                    stat = newstat
                    return self:check_stat(stat, istoplevel)
                end
            end
            stat.vars[i] = self:check_var(stat.vars[i])
            if stat.vars[i]._tag == "ast.Var.Name" then
                local ntag = stat.vars[i]._name._tag
                if ntag == "checker.Name.Function" then
                    type_error(stat.loc,
                        "attempting to assign to toplevel constant function '%s'",
                        stat.vars[i].name)
                elseif ntag == "checker.Name.Builtin" then
                    type_error(stat.loc,
                        "attempting to assign to builtin function %s",
                        stat.vars[i].name)
                end
            end
            stat.exps[i] = self:check_exp_verify(stat.exps[i], stat.vars[i]._type, "assignment")
        end

    elseif tag == "ast.Stat.Call" then
        stat.call_exp = self:check_exp_synthesize(stat.call_exp)

    elseif tag == "ast.Stat.Return" then
        local ret_types = assert(self.ret_types_stack[#self.ret_types_stack])

        self:expand_function_returns(stat.exps)

        if #stat.exps ~= #ret_types then
            type_error(stat.loc,
                "returning %d value(s) but function expects %s",
                #stat.exps, #ret_types)
        end

        for i = 1, #stat.exps do
            stat.exps[i] = self:check_exp_verify(stat.exps[i], ret_types[i], "return statement")
        end

    elseif tag == "ast.Stat.If" then
        stat.condition = self:check_exp_synthesize(stat.condition)
        check_type_is_condition(stat.condition, "if statement condition")
        self:check_stat(stat.then_, false)
        self:check_stat(stat.else_, false)

    elseif tag == "ast.Stat.Break" then
        -- ok

    elseif tag == "ast.Stat.Func" then

        local decl = stat.decl
        local fname_exp = stat.name
        decl._type = self:from_ast_type(decl.type)
        self:check_funcname(fname_exp, decl)
        stat.value =
            self:check_exp_verify(stat.value, decl._type, "toplevel function")

    else
        typedecl.tag_error(tag)
    end

    return stat
end

function Checker:check_funcname(name, decl)
    local var = name.var
    local tag = var._tag
    decl.name = var.name
    if tag == "ast.Var.Dot" then
        local mod_cname = self.symbol_table:find_symbol(var.exp.var.name)
        if mod_cname._tag ~= "checker.Name.Module" then
            type_error(name.loc, "'%s' is not a module", var.exp.var.name)
        end
        name.var = ast.Var.Name(name.loc, var.name)
        decl._modname = var.exp.var.name
    end
    self:add_function(decl)
end

function Checker:check_var(var)
    local tag = var._tag
    if     tag == "ast.Var.Name" then
        local cname = self.symbol_table:find_symbol(var.name)
        if not cname then
            scope_error(var.loc, "variable '%s' is not declared", var.name)
        end
        var._name = cname

        if     cname._tag == "checker.Name.Type" then
            type_error(var.loc, "'%s' isn't a value", var.name)
        elseif cname._tag == "checker.Name.Local" then
            var._type = assert(cname.decl._type)
        elseif cname._tag == "checker.Name.Global" then
            var._type = assert(cname.decl._type)
        elseif cname._tag == "checker.Name.Function" then
            var._type = assert(cname.decl._type)
        elseif cname._tag == "checker.Name.Builtin" then
            var._type = assert(builtins.functions[cname.name])
        elseif cname._tag == "checker.Name.Module" then
            -- Module names can appear only in the dot notation.
            -- For example, a statement like `local x = io` is illegal.
            if cname.is_main_mod then
                var._type = types.T.Module()
            else
                type_error(var.loc,
                    "cannot reference module name '%s' without dot notation",
                    var.name)
            end
        else
            typedecl.tag_error(cname._tag)
        end

    elseif tag == "ast.Var.Dot" then
        local mod_cname
        if var.exp._tag == "ast.Exp.Var" and var.exp.var._tag == "ast.Var.Name" then
            mod_cname = self.symbol_table:find_symbol(var.exp.var.name)
        else
            mod_cname = false
        end

        if mod_cname and mod_cname._tag == "checker.Name.Module" then
            if mod_cname.is_main_mod then
                local module_name = mod_cname.name
                local field_name = var.name
                local internal_name = module_name .. '.' .. field_name
                local cname = self.symbol_table:find_symbol(internal_name)
                if not cname then
                    scope_error(var.loc, "variable '%s' is not declared", internal_name)
                end
                local flat_var = ast.Var.Name(var.exp.loc, field_name)
                flat_var._name = cname
                flat_var._type = cname.decl._type
                var = flat_var
            else
                local module_name = mod_cname.name
                local function_name = var.name
                local internal_name = module_name .. "." .. function_name

                local typ = builtins.functions[internal_name]
                if typ then
                    local cname = self.symbol_table:find_symbol(internal_name)
                    local flat_var = ast.Var.Name(var.exp.loc, internal_name)
                    flat_var._name = cname
                    flat_var._type = typ
                    var = flat_var
                else
                    type_error(var.loc,
                        "unknown function '%s'", internal_name)
                end
            end

        else
            var.exp = self:check_exp_synthesize(var.exp)
            local ind_type = var.exp._type
            if not types.is_indexable(ind_type) then
                type_error(var.loc,
                    "trying to access a member of value of type '%s'",
                    types.tostring(ind_type))
            end
            local field_type = types.indices(ind_type)[var.name]
            if not field_type then
                type_error(var.loc,
                    "field '%s' not found in type '%s'",
                    var.name, types.tostring(ind_type))
            end
            var._type = field_type
        end

    elseif tag == "ast.Var.Bracket" then
        var.t = self:check_exp_synthesize(var.t)
        local arr_type = var.t._type
        if arr_type._tag ~= "types.T.Array" then
            type_error(var.t.loc,
                "expected array but found %s in array indexing",
                types.tostring(arr_type))
        end
        var.k = self:check_exp_verify(var.k, types.T.Integer(), "array indexing")
        var._type = arr_type.elem

    else
        typedecl.tag_error(tag)
    end
    return var
end

local function is_numeric_type(typ)
    return typ._tag == "types.T.Integer" or typ._tag == "types.T.Float"
end

function Checker:coerce_numeric_exp_to_float(exp)
    local tag = exp._type._tag
    if     tag == "types.T.Float" then
        return exp
    elseif tag == "types.T.Integer" then
        return self:check_exp_synthesize(ast.Exp.ToFloat(exp.loc, exp))
    elseif typedecl.match_tag(tag, "types.T") then
        typedecl.tag_error(tag, "this type cannot be coerced to float.")
    else
        typedecl.tag_error(tag)
    end
end

-- Infers the type of expression @exp, ignoring the surrounding type context.
-- Returns the typechecked expression. This may be either the original expression, or an inner
-- expression if we are dropping a redundant type conversion.
function Checker:check_exp_synthesize(exp)
    if exp._type then
        -- This expression was already type-checked before, probably due to expand_function_returns.
        return exp
    end

    local tag = exp._tag
    if     tag == "ast.Exp.Nil" then
        exp._type = types.T.Nil()

    elseif tag == "ast.Exp.Bool" then
        exp._type = types.T.Boolean()

    elseif tag == "ast.Exp.Integer" then
        exp._type = types.T.Integer()

    elseif tag == "ast.Exp.Float" then
        exp._type = types.T.Float()

    elseif tag == "ast.Exp.String" then
        exp._type = types.T.String()

    elseif tag == "ast.Exp.Initlist" then
        type_error(exp.loc, "missing type hint for initializer")

    elseif tag == "ast.Exp.Lambda" then
        type_error(exp.loc, "missing type hint for lambda")

    elseif tag == "ast.Exp.Var" then
        exp.var = self:check_var(exp.var)
        exp._type = exp.var._type

    elseif tag == "ast.Exp.Unop" then
        exp.exp = self:check_exp_synthesize(exp.exp)
        local t = exp.exp._type
        local op = exp.op
        if op == "#" then
            if t._tag ~= "types.T.Array" and t._tag ~= "types.T.String" then
                type_error(exp.loc,
                    "trying to take the length of a %s instead of an array or string",
                    types.tostring(t))
            end
            exp._type = types.T.Integer()
        elseif op == "-" then
            if t._tag ~= "types.T.Integer" and t._tag ~= "types.T.Float" then
                type_error(exp.loc,
                    "trying to negate a %s instead of a number",
                    types.tostring(t))
            end
            exp._type = t
        elseif op == "~" then
            if t._tag ~= "types.T.Integer" then
                type_error(exp.loc,
                    "trying to bitwise negate a %s instead of an integer",
                    types.tostring(t))
            end
            exp._type = types.T.Integer()
        elseif op == "not" then
            check_type_is_condition(exp.exp, "'not' operator")
            exp._type = types.T.Boolean()
        else
            typedecl.tag_error(op)
        end

    elseif tag == "ast.Exp.Binop" then
        exp.lhs = self:check_exp_synthesize(exp.lhs)
        exp.rhs = self:check_exp_synthesize(exp.rhs)
        local t1 = exp.lhs._type
        local t2 = exp.rhs._type
        local op = exp.op
        if op == "==" or op == "~=" then
            if (t1._tag == "types.T.Integer" and t2._tag == "types.T.Float") or
               (t1._tag == "types.T.Float"   and t2._tag == "types.T.Integer") then
                -- Note: if we implement this then we should use the same logic as luaV_equalobj.
                -- Don't just cast to float! That is not accurate for large integers.
                type_error(exp.loc,
                    "comparisons between float and integers are not yet implemented")
            end
            if not types.equals(t1, t2) then
                type_error(exp.loc,
                    "cannot compare %s and %s using %s",
                    types.tostring(t1), types.tostring(t2), op)
            end
            exp._type = types.T.Boolean()

        elseif op == "<" or op == ">" or op == "<=" or op == ">=" then
            if (t1._tag == "types.T.Integer" and t2._tag == "types.T.Integer") or
               (t1._tag == "types.T.Float"   and t2._tag == "types.T.Float") or
               (t1._tag == "types.T.String"  and t2._tag == "types.T.String") then
               -- OK
            elseif (t1._tag == "types.T.Integer" and t2._tag == "types.T.Float") or
                   (t1._tag == "types.T.Float"   and t2._tag == "types.T.Integer") then
                -- Note: if we implement this then we should use the same logic as LTintfloat,
                -- LEintfloat and so on, from lvm.c. Just casting to float is not enough!
                type_error(exp.loc,
                    "comparisons between float and integers are not yet implemented")
            else
                type_error(exp.loc,
                    "cannot compare %s and %s using %s",
                    types.tostring(t1), types.tostring(t2), op)
            end
            exp._type = types.T.Boolean()

        elseif op == "+" or op == "-" or op == "*" or op == "%" or op == "//" then
            if not is_numeric_type(t1) then
                type_error(exp.loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(t1))
            end
            if not is_numeric_type(t2) then
                type_error(exp.loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(t2))
            end

            if t1._tag == "types.T.Integer" and
               t2._tag == "types.T.Integer"
            then
                exp._type = types.T.Integer()
            else
                exp.lhs = self:coerce_numeric_exp_to_float(exp.lhs)
                exp.rhs = self:coerce_numeric_exp_to_float(exp.rhs)
                exp._type = types.T.Float()
            end

        elseif op == "/" or op == "^" then
            if not is_numeric_type(t1) then
                type_error(exp.loc,
                    "left hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(t1))
            end
            if not is_numeric_type(t2) then
                type_error(exp.loc,
                    "right hand side of arithmetic expression is a %s instead of a number",
                    types.tostring(t2))
            end

            exp.lhs = self:coerce_numeric_exp_to_float(exp.lhs)
            exp.rhs = self:coerce_numeric_exp_to_float(exp.rhs)
            exp._type = types.T.Float()

        elseif op == ".." then
            -- The arguments to '..' must be a strings. We do not allow "any" because Pallene does
            -- not allow concatenating integers or objects that implement tostring()
            if t1._tag ~= "types.T.String" then
                type_error(exp.loc, "cannot concatenate with %s value", types.tostring(t1))
            end
            if t2._tag ~= "types.T.String" then
                type_error(exp.loc, "cannot concatenate with %s value", types.tostring(t2))
            end
            exp._type = types.T.String()

        elseif op == "and" or op == "or" then
            check_type_is_condition(exp.lhs, "left hand side of '%s'", op)
            check_type_is_condition(exp.rhs, "right hand side of '%s'", op)
            exp._type = t2

        elseif op == "|" or op == "&" or op == "~" or op == "<<" or op == ">>" then
            if t1._tag ~= "types.T.Integer" then
                type_error(exp.loc,
                    "left hand side of bitwise expression is a %s instead of an integer",
                    types.tostring(t1))
            end
            if t2._tag ~= "types.T.Integer" then
                type_error(exp.loc,
                    "right hand side of bitwise expression is a %s instead of an integer",
                    types.tostring(t2))
            end
            exp._type = types.T.Integer()

        else
            typedecl.tag_error(op)
        end

    elseif tag == "ast.Exp.CallFunc" then
        exp.exp = self:check_exp_synthesize(exp.exp)
        local f_type = exp.exp._type

        if f_type._tag ~= "types.T.Function" then
            type_error(exp.loc,
                "attempting to call a %s value",
                types.tostring(exp.exp._type))
        end

        self:expand_function_returns(exp.args)

        if #f_type.arg_types ~= #exp.args then
            type_error(exp.loc,
                "function expects %d argument(s) but received %d",
                #f_type.arg_types, #exp.args)
        end

        for i = 1, #exp.args do
            exp.args[i] =
                self:check_exp_verify(
                    exp.args[i], f_type.arg_types[i],
                    "argument %d of call to function", i)
        end

        if #f_type.ret_types == 0 then
            exp._type = types.T.Void()
        else
            exp._type  = f_type.ret_types[1] or types.T.Void()
        end
        exp._types = f_type.ret_types

    elseif tag == "ast.Exp.CallMethod" then
        error("not implemented")

    elseif tag == "ast.Exp.Cast" then
        exp._type = self:from_ast_type(exp.target)
        exp.exp = self:check_exp_verify(exp.exp, exp._type, "cast expression")

        -- We check the child expression with verify instead of synthesize because Pallene cases
        -- also act as type annotations for things like empty array literals: ({} as {value}).
        -- However, this means that the call to verify almost always inserts a redundant cast node.
        -- To keep the --dump-checker output clean, we get rid of it.  By the way, the Pallene to
        -- Lua translator cares that we remove the inner one instead of the outer one because the
        -- outer one has source locations and the inner one doesn't.
        while
            exp.exp._tag == 'ast.Exp.Cast' and
            exp.exp.target == false and
            types.equals(exp.exp._type, exp._type)
        do
            exp.exp = exp.exp.exp
        end

    elseif tag == "ast.Exp.Paren" then
        exp.exp = self:check_exp_synthesize(exp.exp)
        exp._type = exp.exp._type

    elseif tag == "ast.Exp.ExtraRet" then
        exp._type = exp.call_exp._types[exp.i]

    elseif tag == "ast.Exp.ToFloat" then
        assert(exp.exp._type._tag == "types.T.Integer")
        exp._type = types.T.Float()

    else
        typedecl.tag_error(tag)
    end

    return exp
end

-- Verifies that expression @exp has type expected_type.
-- Returns the typechecked expression. This may be either the original
-- expression, or a coercion node from the original expression to the expected
-- type.
--
-- errmsg_fmt: format string describing where we got @expected_type from
-- ... : arguments to the "errmsg_fmt" format string
function Checker:check_exp_verify(exp, expected_type, errmsg_fmt, ...)
    if not expected_type then
        error("expected_type is required")
    end

    local tag = exp._tag
    if tag == "ast.Exp.Initlist" then

        if expected_type._tag == "types.T.Array" then
            for _, field in ipairs(exp.fields) do
                local ftag = field._tag
                if ftag == "ast.Field.Rec" then
                    type_error(field.loc,
                        "named field '%s' in array initializer",
                        field.name)
                elseif ftag == "ast.Field.List" then
                    field.exp = self:check_exp_verify(
                        field.exp, expected_type.elem,
                        "array initializer")
                else
                    typedecl.tag_error(ftag)
                end
            end
        elseif expected_type._tag == "types.T.Module" then
            -- Fallthrough to default

        elseif types.is_indexable(expected_type) then
            local initialized_fields = {}
            for _, field in ipairs(exp.fields) do
                local ftag = field._tag
                if ftag == "ast.Field.List" then
                    type_error(field.loc,
                        "table initializer has array part")
                elseif ftag == "ast.Field.Rec" then
                    if initialized_fields[field.name] then
                        type_error(field.loc,
                            "duplicate field '%s' in table initializer",
                            field.name)
                    end
                    initialized_fields[field.name] = true

                    local field_type = types.indices(expected_type)[field.name]
                    if not field_type then
                        type_error(field.loc,
                            "invalid field '%s' in table initializer for %s",
                            field.name, types.tostring(expected_type))
                    end

                    field.exp = self:check_exp_verify(
                        field.exp, field_type,
                        "table initializer")
                else
                    typedecl.tag_error(ftag)
                end
            end

            for field_name, _ in pairs(types.indices(expected_type)) do
                if not initialized_fields[field_name] then
                    type_error(exp.loc,
                        "required field '%s' is missing from initializer",
                        field_name)
                end
            end
        else
            type_error(exp.loc,
                "type hint for initializer is not an array, table, or record type")
        end

    elseif tag == "ast.Exp.Lambda" then

        -- These assertions are always true in the current version of Pallene, which does not allow
        -- nested function expressions. Once we add function expressions to the parser then we
        -- should convert these assertions into proper calls to type_error.
        assert(expected_type._tag == "types.T.Function")
        assert(#expected_type.arg_types == #exp.arg_decls)

        table.insert(self.ret_types_stack, expected_type.ret_types)
        self.symbol_table:with_block(function()
            for i, decl in ipairs(exp.arg_decls) do
                decl._type = assert(expected_type.arg_types[i])
                self:add_local(decl)
            end
            self:check_stat(exp.body, false)
        end)
        table.remove(self.ret_types_stack)

    elseif tag == "ast.Exp.Paren" then
        exp.exp = self:check_exp_verify(exp.exp, expected_type, errmsg_fmt, ...)

    else

        exp = self:check_exp_synthesize(exp)
        local found_type = exp._type

        if not types.equals(found_type, expected_type) then
            if types.consistent(found_type, expected_type) then
                exp = ast.Exp.Cast(exp.loc, exp, false)

            else
                type_error(exp.loc, string.format(
                    "expected %s but found %s in %s",
                    types.tostring(expected_type),
                    types.tostring(found_type),
                    string.format(errmsg_fmt, ...)))
            end
        end
    end

    -- If we have reached this point, the type should be correct. But to be safe, we assert that the
    -- type annotation is correct, if it has already been set by check_exp_synthesize.
    exp._type = exp._type or expected_type
    assert(types.equals(exp._type, expected_type))

    -- Be aware that some of the cases might have reassigned the `exp` variable so it won't
    -- necessarily be the same as the input `exp` we received.
    return exp
end

-- Typechecks an initializer `x : ast_typ = exp`, where the type annotation is optional.
-- Sets decl._type and exp._type
function Checker:check_initializer_exp(decl, exp, err_fmt, ...)
    if decl.type then
        decl._type = self:from_ast_type(decl.type)
        if exp ~= nil then
            return self:check_exp_verify(exp, decl._type, err_fmt, ...)
        else
            return nil
        end
    else
        if exp ~= nil then
            local e = self:check_exp_synthesize(exp)
            decl._type = e._type
            return e
        else
            type_error(decl.loc, string.format(
                "uninitialized variable '%s' needs a type annotation",
                decl.name))
        end
    end
end

return checker
