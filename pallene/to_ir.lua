-- Copyright (c) 2020, The Pallene Developers
-- Pallene is licensed under the MIT license.
-- Please refer to the LICENSE and AUTHORS files for details
-- SPDX-License-Identifier: MIT

local ir = require "pallene.ir"
local types = require "pallene.types"
local util = require "pallene.util"
local typedecl = require "pallene.typedecl"

local to_ir = {}

local function declare_type(type_name, cons)
    typedecl.declare(to_ir, "to_ir", type_name, cons)
end

declare_type("LHS", {
    Local  = {"id"},
    Global = {"id"},
    Array  = {"typ", "arr", "i"},
    Table  = {"typ", "t", "field"},
    Record = {"typ", "rec", "field"},
})

declare_type("Var", {
    LocalVar   = {"id"},
    Upvalue    = {"id"},
    GlobalVar  = {"id"},
})

local ToIR = util.Class()

function to_ir.convert(prog_ast)
    assert(prog_ast._tag == "ast.Program.Program")
    local module = ToIR.new():convert_toplevel(prog_ast.tls)
    ir.clean_all(module)
    return module, {}
end

function to_ir.FuncInfo(f_id, func)
    return {
        loc_id_of_decl   = {},   -- { ast.Decl => integer }
        upval_id_of_decl = {},   -- { ast.Decl => integer }
        func             = func, -- ast.Exp.Lambda
        f_id             = f_id  -- integer
    }
end

--
--
--

function ToIR:init()
    -- Module-level variables
    self.module = ir.Module()
    self.rec_id_of_typ  = {} -- { types.T  => integer }
    self.fun_id_of_exp  = {} -- { ast.Exp  => integer }
    self.glb_id_of_decl = {} -- { ast.Decl => integer } -- non-exported globals
    self.glb_id_of_var  = {} -- { ast.Var  => integer } -- exported global
    self.func_stack     = {} -- list of function to_ir.FuncInfo
    self.call_exps      = {} -- { ast.Exp.CallFunc }
    self.dsts_of_call   = {} -- { ast.Exp => { var_id } }
end

function ToIR:enter_function(f_id)
    -- Function-specific variables
    -- These are re-initialized each time.
    local func_info = to_ir.FuncInfo(f_id, self.module.functions[f_id])
    table.insert(self.func_stack, func_info)

    self.func           = func_info.func
    self.loc_id_of_decl = func_info.loc_id_of_decl
end

function ToIR:exit_function(cmds)
    -- Create temporary destination variables for any unused function return values.
    for _, call_exp in ipairs(self.call_exps) do
        local dsts = self.dsts_of_call[call_exp]
        for i = 1, #dsts do
            if not dsts[i] then
                local typ = assert(call_exp._types[i])
                dsts[i] = ir.add_local(self.func, "$unused_ret", typ)
            end
        end
    end

    self.func.body = ir.Cmd.Seq(cmds)

    table.remove(self.func_stack, #self.func_stack)
    local current_func = self.func_stack[#self.func_stack]

    if current_func then
        self.func           = current_func.func
        self.loc_id_of_decl = current_func.loc_id_of_decl
    else
        self.func           = nil
        self.loc_id_of_decl = nil
    end
end

-- Returns a to_ir.Var object containing ID of `decl`.
-- If `decl` resolves to an upvalue, then it registers the upvalue in the intermediate
-- and current function.
function ToIR:resolve_variable(decl)
    if decl._tag == "ast.Var.Name" then
        local glb_id = assert(self.glb_id_of_var[decl])
        return to_ir.Var.GlobalVar(glb_id)
    end
    assert(decl._tag == "ast.Decl.Decl")

    local glb_id = self.glb_id_of_decl[decl]
    if glb_id then
        return to_ir.Var.GlobalVar(glb_id)
    end

    local stack_id, var
    for i = 1, #self.func_stack do
        local loc_id = self.func_stack[i].loc_id_of_decl[decl]
        if loc_id then
            var = to_ir.Var.LocalVar(loc_id)
            stack_id = i
            break
        end
    end

    assert(var)
    assert(stack_id)
    for i = stack_id + 1, #self.func_stack do
        local func_info = self.func_stack[i]
        local func      = func_info.func
        local u_id
        if func_info.upval_id_of_decl[decl] then
            u_id = func_info.upval_id_of_decl[decl]
        elseif var._tag == "to_ir.Var.LocalVar" then
            u_id = ir.add_upvalue(func, decl.name, decl._type, ir.Value.LocalVar(var.id))
        elseif var._tag == "to_ir.Var.Upvalue" then
            u_id = ir.add_upvalue(func, decl.name, decl._type, ir.Value.Upvalue(var.id))
        else
            typedecl.tag_error(var._tag)
        end
        func_info.upval_id_of_decl[decl] = u_id
        var = to_ir.Var.Upvalue(u_id)
    end

    return var
end

function ToIR:register_lambda(exp, name)
    assert(exp._tag == "ast.Exp.Lambda")
    is_imported = is_imported or false
    local f_id = ir.add_function(self.module, exp.loc, name, exp._type)
    self.fun_id_of_exp[exp] = f_id
    return f_id
end

function ToIR:register_function(stat)
    assert(stat._tag == "ast.Stat.Func")
    if stat.is_local then
        assert(not stat.module)
        assert(not stat.method)
    else
        assert(not stat.method)
    end

    local f_id = self:register_lambda(stat.value, stat.name)

    if stat.module then
        ir.add_exported_function(self.module, f_id)
    end
end

function ToIR:register_imported_function(stat, mod_name)
    assert(stat._tag == "ast.Stat.Func")
    assert(not stat.is_local)
    assert(stat.module)

    return ir.add_imported_function(self.module, mod_name, stat.name, stat.value._type)
end

function ToIR:convert_toplevel(prog_ast)

    -- Create the $init function (it must have ID = 1)
    ir.add_function(self.module, false, "$init", types.T.Function({}, {}))

    -- Initialize the module-level variables
    self:enter_function(1)
    local cmds = {}
    for _, tl_node in ipairs(prog_ast) do
        local tag = tl_node._tag
        if tag == "ast.Toplevel.Stats" then
            for _, stat in ipairs(tl_node.stats) do
                local stag = stat._tag
                if     stag == "ast.Stat.Assign" then
                    for _, var in ipairs(stat.vars) do
                        if var._exported_as then
                            assert(var._type)
                            local g_id = ir.add_global(self.module, var.name, var._type)
                            self.glb_id_of_var[var] = g_id
                            ir.add_exported_global(self.module, g_id)
                        end
                    end

                elseif stag == "ast.Stat.Decl" then
                    for _, decl in ipairs(stat.decls) do
                        assert(decl._type)
                        local g_id = ir.add_global(self.module, decl.name, decl._type)
                        self.glb_id_of_decl[decl] = g_id
                    end

                elseif stag == "ast.Stat.Func" then
                    self:register_function(stat)
                elseif stag == "ast.Stat.LetRec" then
                    for _, func in ipairs(stat.func_stats) do
                        self:register_function(func)
                    end
                end
            end
        elseif tag == "ast.Toplevel.Typealias" then
            --skip
        elseif tag == "ast.Toplevel.Record" then
            local typ = tl_node._type
            self.rec_id_of_typ[typ] = ir.add_record_type(self.module, typ)
        else
            typedecl.tag_error(tag)
        end
    end

    for _, tl_node in ipairs(prog_ast) do
        if tl_node._tag == "ast.Toplevel.Stats" then
            for _, stat in ipairs(tl_node.stats) do
                self:convert_stat(cmds, stat)
            end
        else
            -- skip
        end
    end
    self:exit_function(cmds)

    return self.module
end


function ToIR:convert_stats(cmds, stats)
    for i = 1, #stats do
        self:convert_stat(cmds, stats[i])
    end
end

-- Converts a typechecked ast.Stat into a list of ir.Cmd
-- The converted ir.Cmd nodes are appended to the @cmds list
function ToIR:convert_stat(cmds, stat)
    local tag = stat._tag
    if     tag == "ast.Stat.Block" then
        self:convert_stats(cmds, stat.stats)

    elseif tag == "ast.Stat.While" then
        local body = {}
        local cond     = self:exp_to_value(body, stat.condition)
        local condBool = self:value_is_truthy(body, stat.condition, cond)
        table.insert(body, ir.Cmd.If(stat.loc, condBool, ir.Cmd.Nop(), ir.Cmd.Break()))
        self:convert_stat(body, stat.block)
        table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.Repeat" then
        local body = {}
        self:convert_stat(body, stat.block)
        local cond     = self:exp_to_value(body, stat.condition)
        local condBool = self:value_is_truthy(body, stat.condition, cond)
        table.insert(body, ir.Cmd.If(stat.loc, condBool, ir.Cmd.Break(), ir.Cmd.Nop()))
        table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.If" then
        local cond     = self:exp_to_value(cmds, stat.condition)
        local condBool = self:value_is_truthy(cmds, stat.condition, cond)
        local then_ = {}; self:convert_stat(then_, stat.then_)
        local else_ = {}; self:convert_stat(else_, stat.else_)
        table.insert(cmds, ir.Cmd.If(stat.loc, condBool, ir.Cmd.Seq(then_), ir.Cmd.Seq(else_)))

    elseif tag == "ast.Stat.ForNum" then
        local start = self:exp_to_value(cmds, stat.start)
        local limit = self:exp_to_value(cmds, stat.limit)
        local step  = self:exp_to_value(cmds, stat.step)

        local decl = stat.decl
        local v = ir.add_local(self.func, decl.name, decl._type)
        self.loc_id_of_decl[decl] = v

        local body = {}
        self:convert_stat(body, stat.block)

        table.insert(cmds, ir.Cmd.For(stat.loc, v, start, limit, step, ir.Cmd.Seq(body)))

    elseif tag == "ast.Stat.ForIn" then
        local decls = stat.decls
        local exps = stat.exps

        local e1 = exps[1]
        local is_ipairs = (
            e1._tag == "ast.Exp.CallFunc" and
            e1.exp._tag == "ast.Exp.Var" and
            e1.exp.var._def._tag == "checker.Def.Builtin" and
            e1.exp.var._def.id == "ipairs")


        if is_ipairs then
            -- `ipairs` are desugared down to regular for-loops
            -- ```
            -- for i: T1, x: T2 in ipairs(xs) do
            --   <loop body>
            -- end
            -- ```
            -- would get compiled down to:
            -- ```
            -- local i_num: integer = 1
            -- while true do
            --   local x_dyn = xs[i_num]
            --   if x_dyn == nil then
            --     break
            --   end
            --   local i = i_num as T1
            --   local x = x_dyn as T2
            --   <loop body>
            --   i_num = i_num + 1
            -- end
            -- ```


            local ipairs_args = exps[2].call_exp.args
            assert(#ipairs_args == 1)
            assert(#decls == 2)

            -- the table passed as argument to `ipairs`
            local arr =  ipairs_args[1]
            assert(types.equals(arr._type, types.T.Array(types.T.Any())))
            local v_arr = ir.add_local(self.func, "$xs", arr._type)
            self:exp_to_assignment(cmds, v_arr, arr)

            -- local i_num: integer = 1
            local v_inum = ir.add_local(self.func, "$"..decls[1].name.."_num", types.T.Integer())
            local start = ir.Value.Integer(1)
            table.insert(cmds, ir.Cmd.Move(stat.loc, v_inum, start))

            -- body of the while loop.
            local body = {}

            -- x_dyn = xs[i_num]
            local v_x_dyn = ir.add_local(self.func, "$"..decls[2].name.."_dyn", types.T.Any())
            local src_arr =  ir.Value.LocalVar(v_arr)
            local src_i =  ir.Value.LocalVar(v_inum)
            table.insert(body, ir.Cmd.GetArr(stat.loc, types.T.Any(), v_x_dyn, src_arr, src_i))

            -- if x_dyn == nil then break end
            local v_cond_checknil = ir.add_local(self.func, false, types.T.Boolean())
            table.insert(body, ir.Cmd.IsNil(stat.loc, v_cond_checknil, ir.Value.LocalVar(v_x_dyn)))
            table.insert(body, ir.Cmd.If(stat.loc, ir.Value.LocalVar(v_cond_checknil), ir.Cmd.Break(), ir.Cmd.Nop()))

            -- local i: T1 = i_num as T1
            local v_i = ir.add_local(self.func, decls[1].name, decls[1]._type)
            self.loc_id_of_decl[decls[1]] = v_i
            if decls[1]._type._tag == "types.T.Integer" then
                table.insert(body, ir.Cmd.Move(stat.loc, v_i, ir.Value.LocalVar(v_inum)))
            else
                table.insert(body, ir.Cmd.ToDyn(stat.loc, types.T.Integer(), v_i, ir.Value.LocalVar(v_inum)))
            end

            -- local x = x_dyn as T2
            local v_x = ir.add_local(self.func, decls[2].name, decls[2]._type)
            self.loc_id_of_decl[decls[2]] = v_x
            if decls[2]._type._tag == "types.T.Any" then
                table.insert(body, ir.Cmd.Move(stat.loc, v_x, ir.Value.LocalVar(v_x_dyn)))
            else
                table.insert(body, ir.Cmd.FromDyn(stat.loc, decls[2]._type, v_x, ir.Value.LocalVar(v_x_dyn)))
            end

            -- <loop body>
            self:convert_stat(body, stat.block)
            -- i_num = i_num + 1
            local loop_step = ir.Value.Integer(1)
            table.insert(body, ir.Cmd.Binop(stat.loc, v_inum, "IntAdd", ir.Value.LocalVar(v_inum), loop_step))

            table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))

        else

            -- Regular for-in loops are desugared into regurlar loops before compiling.
            -- For example, a loop like this:
            --- ```
            -- for a: T1, b: T2 in <RHS> do
            --     <loop body>
            -- end
            ---```
            -- is compiled as if the following was written instead:
            --```
            -- local iter, st, a_dyn, b_dyn
            -- iter, st, ctrl = RHS[1], RHS[2], RHS[3]
            -- while true do
            --   a_dyn, b_dyn = iter(st, a_dyn)
            --   if a_dyn == nil then break end
            --   local a = a_dyn as T1
            --   local b = b_dyn as T2
            --   <loop body>
            -- end
            -- ```

            local v_iter = ir.add_local(self.func, "$iter", exps[1]._type)
            self:exp_to_assignment(cmds, v_iter, exps[1])
            local v_state = ir.add_local(self.func, "$st", exps[2]._type)
            self:exp_to_assignment(cmds, v_state, exps[2])

            local v_lhs_dyn = {}
            for _, decl in ipairs(decls) do
                local v = ir.add_local(self.func, "$" .. decl.name .. "_dyn", types.T.Any())
                table.insert(v_lhs_dyn, v)
            end

            local v_ctrl = v_lhs_dyn[1]
            self:exp_to_assignment(cmds, v_ctrl, exps[3])

            --Body of the `while` loop.
            local body = {}

            local itertype = exps[1]._type
            local args = { ir.Value.LocalVar(v_state), ir.Value.LocalVar(v_ctrl) }
            table.insert(body, ir.Cmd.CallDyn(exps[1].loc, itertype, v_lhs_dyn, ir.Value.LocalVar(v_iter), args))

            -- if i == nil then break end
            local v_cond = ir.add_local(self.func, false, types.T.Boolean())
            table.insert(body, ir.Cmd.IsNil(stat.loc, v_cond, ir.Value.LocalVar(v_lhs_dyn[1])))
            table.insert(body, ir.Cmd.If(stat.loc, ir.Value.LocalVar(v_cond), ir.Cmd.Break(), ir.Cmd.Nop()))

            -- cast loop LHS to annotated types.
            for i, decl in ipairs(decls) do
                if decl._type.tag == "types.T.Any" then
                    self.loc_id_of_decl[decl] = v_lhs_dyn[i]
                else
                    local v_typed = ir.add_local(self.func, decl.name, decl._type)
                    local val = ir.Value.LocalVar(v_lhs_dyn[i])
                    table.insert(body, ir.Cmd.FromDyn(stat.loc, decl._type, v_typed, val))
                    self.loc_id_of_decl[decl] = v_typed
                end
            end

            self:convert_stat(body, stat.block)
            table.insert(cmds, ir.Cmd.Loop(ir.Cmd.Seq(body)))
        end

    elseif tag == "ast.Stat.Assign" then
        local loc = stat.loc
        local vars = stat.vars
        local exps = stat.exps

        assert(#vars <= #exps)

        -- Multiple Assignments
        -- --------------------
        -- According to the Lua reference manual, the expressions in a multiple assignment should be
        -- evaluated before the assignments are performed. The order of evaluation is not specified
        -- but we try to match what PUC-Lua does: it evaluates the expressions from left to right
        -- and then performs the assignments from right to left.

        -- In a multiple assignment we have to be careful if we end up with an ir.Value that refers
        -- to a local variable because that variable can potentially be overwritten in another part
        -- of the the assignment.  When that happens we need to save the value to a temporary
        -- variable before resolving the assignments.
        local function save_if_necessary(exp, i)
            local val = self:exp_to_value(cmds, exp)
            if  val._tag == "ir.Value.LocalVar" then
                for j = i+1, #vars do
                    local var = vars[j]
                    if  var._tag == "ast.Var.Name" and
                        var._def._tag == "checker.Def.Variable" and
                        self.loc_id_of_decl[var._def.decl] == val.id
                    then
                        local v = ir.add_local(self.func, false, exp._type)
                        table.insert(cmds, ir.Cmd.Move(loc, v, val))
                        return ir.Value.LocalVar(v)
                    end
                end
            end
            return val
        end

        local lhss = {}
        for i, var in ipairs(vars) do
            if     var._tag == "ast.Var.Name" then
                assert(var._def._tag == "checker.Def.Variable")
                local var_info = self:resolve_variable(var._def.decl)
                if var_info._tag == "to_ir.Var.LocalVar" then
                    table.insert(lhss, to_ir.LHS.Local(var_info.id))
                elseif var_info._tag == "to_ir.Var.Upvalue" then
                    error("Mutable upvalues not implemented")
                elseif var_info._tag == "to_ir.Var.GlobalVar" then
                    table.insert(lhss, to_ir.LHS.Global(var_info.id))
                else
                    typedecl.tag_error(var_info._tag)
                end

            elseif var._tag == "ast.Var.Bracket" then
                local typ = stat.exps[i]._type
                local t = save_if_necessary(var.t, i)
                local k = save_if_necessary(var.k, i)
                table.insert(lhss, to_ir.LHS.Array(typ, t, k))

            elseif var._tag == "ast.Var.Dot" then
                local t = save_if_necessary(var.exp, i)
                local ttag = var.exp._type._tag
                if     ttag == "types.T.Table" then
                    local typ = stat.exps[i]._type
                    table.insert(lhss, to_ir.LHS.Table(typ, t, var.name))
                elseif ttag == "types.T.Record" then
                    local typ = var.exp._type
                    table.insert(lhss, to_ir.LHS.Record(typ, t, var.name))
                elseif typedecl.tag_is_type(ttag) then
                    typedecl.tag_error(ttag, "type not indexable.")
                else
                    typedecl.tag_error(ttag)
                end

            else
                typedecl.tag_error(var._tag)
            end
        end

        -- We'd like to avoid storing the RHS results in temporary variables when possible, to avoid
        -- cluttering the generated code with too many variables. There are three main cases:
        --
        --  1) If the expression is the rightmost one in the RHS then we are free to use
        --  exp_to_assignment because this is also the first assignment to be resolved.
        --  This is always the case for a single assignment.
        --
        -- The other cases are for expressions that are not the rightmost one in the RHS.
        --
        --  2) If the exp is something simple that can be evaluated with exp_to_value then the thing
        --  that we need to worry about is if we are reading from a local variable that is being
        --  assigned in another part of this multi-assignment. We can take care of this with
        --  save_if_necessary.
        --
        --  3) If the expression is something more complex that expects to be evaluated with
        --  exp_to_assignment then in theory we could use exp_to_assignment if we could prove that
        --  it is safe to write to the destination variables at this point in the program, before
        --  the rest of the RHS has been evaluated. However, we don't bother optimizing this last
        --  case because if the programmer has written a complicated multiple-assignment then it is
        --  likely that it isn't something that could have been written as a sequence of single
        --  assignments. Our implementation always ends up creating a temporary variable in this
        --  case because save_if_necessary calls exp_to_value.
        local vals = {}
        for i, exp in ipairs(exps) do
            if i <= #vars then
                local is_extraret = (exp._tag == "ast.Exp.ExtraRet")
                local is_mulfun   = (exp._tag == "ast.Exp.CallFunc" and
                                     exp[i+1] and exp[i+1]._tag == "ast.Exp.ExtraRet")
                local is_last = (i == #vars) or is_mulfun or is_extraret
                if is_last and lhss[i] and lhss[i]._tag == "to_ir.LHS.Local" then
                    self:exp_to_assignment(cmds, lhss[i].id, exp)
                    vals[i] = false
                else
                    vals[i] = save_if_necessary(exp, i)
                end
            else
                vals[i] = self:exp_to_value(cmds, exp)
            end
        end

        for i = #vars, 1, -1 do
            local lhs = lhss[i]
            local val = vals[i]
            if val then
                local ltag = lhs._tag
                if     ltag == "to_ir.LHS.Local" then
                    table.insert(cmds, ir.Cmd.Move(loc, lhs.id, val))
                elseif ltag == "to_ir.LHS.Global" then
                    table.insert(cmds, ir.Cmd.SetGlobal(loc, lhs.id, val))
                elseif ltag == "to_ir.LHS.Array" then
                    table.insert(cmds, ir.Cmd.SetArr(loc, lhs.typ, lhs.arr, lhs.i, val))
                elseif ltag == "to_ir.LHS.Table" then
                    local str = ir.Value.String(lhs.field)
                    table.insert(cmds, ir.Cmd.SetTable(loc, lhs.typ, lhs.t, str, val))
                elseif ltag == "to_ir.LHS.Record" then
                    table.insert(cmds, ir.Cmd.SetField(loc, lhs.typ, lhs.rec, lhs.field, val))
                else
                    typedecl.tag_error(ltag)
                end
            end
        end

    elseif tag == "ast.Stat.Decl" then
        for _, decl in ipairs(stat.decls) do
            local typ = decl._type
            if not self.glb_id_of_decl[decl] then
                self.loc_id_of_decl[decl] = ir.add_local(self.func, decl.name, typ)
            end
        end

        for i, exp in ipairs(stat.exps) do
            local decl = stat.decls[i]
            if decl then
                local g_id = self.glb_id_of_decl[decl]
                if g_id then
                    local val = self:exp_to_value(cmds, exp)
                    table.insert(cmds, ir.Cmd.SetGlobal(decl.loc, g_id, val))
                else
                    self:exp_to_assignment(cmds, self.loc_id_of_decl[decl], exp)
                end
            else
                -- Extra argument to RHS; compute it for side effects and discard result
                local _ = self:exp_to_value(cmds, exp)
            end
        end

    elseif tag == "ast.Stat.Call" then
        self:exp_to_assignment(cmds, false, stat.call_exp)

    elseif tag == "ast.Stat.Return" then
        local vals = {}
        for i, exp in ipairs(stat.exps) do
            vals[i] = self:exp_to_value(cmds, exp)
        end
        table.insert(cmds, ir.Cmd.Return(stat.loc, vals))

    elseif tag == "ast.Stat.Break" then
        table.insert(cmds, ir.Cmd.Break())

    elseif tag == "ast.Stat.Func" then
        assert(stat.value and stat.value._tag == "ast.Exp.Lambda")
        self:convert_func(stat.value)

    elseif tag == "ast.Stat.LetRec" then
        for _ , func in ipairs(stat.func_stats) do
            self:convert_stat(cmds, func)
        end

    else
        typedecl.tag_error(tag)
    end
end

function ToIR:convert_func(lambda)
    self:enter_function(self.fun_id_of_exp[lambda])
    for _, decl in ipairs(lambda.arg_decls) do
      self.loc_id_of_decl[decl] = ir.add_local(self.func, decl.name, decl._type)
    end

    local f_cmds = {}
    self:convert_stat(f_cmds, lambda.body)
    self:exit_function(f_cmds)
end


local unops = {
    { "#",   "Array",   "ArrLen"  },
    { "#",   "String",  "StrLen"  },
    { "-",   "Integer", "IntNeg"  },
    { "-",   "Float",   "FltNeg"  },
    { "~",   "Integer", "BitNeg"  },
    { "not", "Boolean", "BoolNot" },
}

local binops = {
    { "+"  , "Integer", "Integer", "IntAdd"  },
    { "-"  , "Integer", "Integer", "IntSub"  },
    { "*"  , "Integer", "Integer", "IntMul"  },
    { "//" , "Integer", "Integer", "IntDivi" },
    { "%"  , "Integer", "Integer", "IntMod"  },

    { "+"  , "Float",   "Float",   "FltAdd"  },
    { "-"  , "Float",   "Float",   "FltSub"  },
    { "*"  , "Float",   "Float",   "FltMul"  },
    { "//" , "Float",   "Float",   "FltDivi" },
    { "%"  , "Float",   "Float",   "FltMod"  },
    { "/"  , "Float",   "Float",   "FltDiv"  },

    { "&" , "Integer", "Integer", "BitAnd"    },
    { "|" , "Integer", "Integer", "BitOr"     },
    { "~" , "Integer", "Integer", "BitXor"    },
    { "<<", "Integer", "Integer", "BitLShift" },
    { ">>", "Integer", "Integer", "BitRShift" },

    { "^" , "Float",   "Float",   "FltPow" },

    { "==", "Any",   "Any",   "AnyEq"  },
    { "~=", "Any",   "Any",   "AnyNeq" },

    { "==", "Nil",     "Nil",     "NilEq"  },
    { "~=", "Nil",     "Nil",     "NilNeq" },

    { "==", "Boolean", "Boolean", "BoolEq"  },
    { "~=", "Boolean", "Boolean", "BoolNeq" },

    { "==", "Integer", "Integer", "IntEq"  },
    { "~=", "Integer", "Integer", "IntNeq" },
    { "<" , "Integer", "Integer", "IntLt"  },
    { ">" , "Integer", "Integer", "IntGt"  },
    { "<=", "Integer", "Integer", "IntLeq" },
    { ">=", "Integer", "Integer", "IntGeq" },

    { "==", "Float",   "Float",   "FltEq"  },
    { "~=", "Float",   "Float",   "FltNeq" },
    { "<" , "Float",   "Float",   "FltLt"  },
    { ">" , "Float",   "Float",   "FltGt"  },
    { "<=", "Float",   "Float",   "FltLeq" },
    { ">=", "Float",   "Float",   "FltGeq" },

    { "==", "String",  "String",   "StrEq"  },
    { "~=", "String",  "String",   "StrNeq" },
    { "<" , "String",  "String",   "StrLt"  },
    { ">" , "String",  "String",   "StrGt"  },
    { "<=", "String",  "String",   "StrLeq" },
    { ">=", "String",  "String",   "StrGeq" },

    { "==", "Function","Function", "FunctionEq"  },
    { "~=", "Function","Function", "FunctionNeq" },

    { "==", "Array",   "Array",    "ArrayEq"    },
    { "~=", "Array",   "Array",    "ArrayNeq"    },

    { "==", "Table",   "Table",    "TableEq"    },
    { "~=", "Table",   "Table",    "TableNeq"    },

    { "==", "Record",  "Record",   "RecordEq",  },
    { "~=", "Record",  "Record",   "RecordNeq",  },
}

local function type_specific_unop(op, typ)
   for _, x in ipairs(unops) do
        local op_, typ_, name = x[1], x[2], x[3]
        if
            op == op_ and
            typ._tag == ("types.T." .. typ_)
        then
            return name
        end
    end
    error("impossible")
end

local function type_specific_binop(op, typ1, typ2)
    for _, x in ipairs(binops) do
        local op_, typ1_, typ2_, name = x[1], x[2], x[3], x[4]
        if
            op == op_ and
            typ1._tag == ("types.T." .. typ1_) and
            typ2._tag == ("types.T." .. typ2_)
        then
            return name
        end
    end
    error("impossible")
end

-- Converts a typechecked ast.Exp to a ir.Value. If necessary, will create a fresh variable, and add
-- intermediate computations to the @cmds list.
function ToIR:exp_to_value(cmds, exp, _recursive)
    local tag = exp._tag
    if     tag == "ast.Exp.Nil" then
        return ir.Value.Nil()

    elseif tag == "ast.Exp.Bool" then
        return ir.Value.Bool(exp.value)

    elseif tag == "ast.Exp.Integer" then
        return ir.Value.Integer(exp.value)

    elseif tag == "ast.Exp.Float" then
        return ir.Value.Float(exp.value)

    elseif tag == "ast.Exp.String" then
        return ir.Value.String(exp.value)

    elseif tag == "ast.Exp.Var" then
        local var = exp.var
        if     var._tag == "ast.Var.Name" then
            local def = var._def
            if var._mod_name then
                local var_name
                if def._tag == "checker.Def.Variable" then
                    var_name = def.decl._exported_as
                    local imported_var = { name = var_name, mod = var._mod_name, typ = var._type }
                    table.insert(self.module.imported_vars, imported_var)
                    return ir.Value.ImportedVar(#self.module.imported_vars)
                else
                    var_name = def.stat.name
                    local id = self:register_imported_function(def.stat, var._mod_name)
                    return ir.Value.ImportedFunction(id)
                end
            end
            if     def._tag == "checker.Def.Variable" then
                local var_info = self:resolve_variable(def.decl)
                if var_info._tag == "to_ir.Var.LocalVar" then
                    return ir.Value.LocalVar(var_info.id)
                elseif var_info._tag == "to_ir.Var.Upvalue" then
                    return ir.Value.Upvalue(var_info.id)
                elseif var_info._tag == "to_ir.Var.GlobalVar" then

                    -- Fallthrough to default
                else
                    typedecl.tag_error(var_info._tag)
                end

            elseif def._tag == "checker.Def.Function" then
                local id = self.fun_id_of_exp[def.stat.value]
                return ir.Value.Function(id)

            elseif def._tag == "checker.Def.Builtin" then
                error("not implemented")

            else
                typedecl.tag_error(def._tag)
            end

        else
            -- Fallthrough to default
        end

    elseif tag == "ast.Exp.Paren" then
        return self:exp_to_value(cmds, exp.exp)
    end

    if _recursive then
        -- Avoid infinite loop due to type error
        error(string.format(
            "Neither exp_to_value or exp_to_assignment handled tag %q)",
            exp._tag))
    end

    -- Otherwise we need to create a temporary variable
    local v = ir.add_local(self.func, false, exp._type)
    self:exp_to_assignment(cmds, v, exp)
    return ir.Value.LocalVar(v)
end

-- Converts the assignment `dst = exp` into a list of ir.Cmd, which are added to the @cmds list.
-- If this is a function call, then dst may be false
function ToIR:exp_to_assignment(cmds, dst, exp)
    local loc = exp.loc
    local tag = exp._tag

    local use_exp_to_value = false

    if not dst then
        assert(tag == "ast.Exp.CallFunc" or tag == "ast.Exp.CallMethod")
    end

    if     tag == "ast.Exp.InitList" then
        local typ = exp._type
        if     typ._tag == "types.T.Array" then
            local n = ir.Value.Integer(#exp.fields)
            table.insert(cmds, ir.Cmd.NewArr(loc, dst, n))
            table.insert(cmds, ir.Cmd.CheckGC())
            for i, field in ipairs(exp.fields) do
                assert(field._tag == "ast.Field.List")
                local av = ir.Value.LocalVar(dst)
                local iv = ir.Value.Integer(i)
                local vv = self:exp_to_value(cmds, field.exp)
                local src_typ = field.exp._type
                table.insert(cmds, ir.Cmd.SetArr(loc, src_typ, av, iv, vv))
            end

        elseif typ._tag == "types.T.Table" then
            local n = ir.Value.Integer(#exp.fields)
            table.insert(cmds, ir.Cmd.NewTable(loc, dst, n))
            table.insert(cmds, ir.Cmd.CheckGC())
            for _, field in ipairs(exp.fields) do
                assert(field._tag == "ast.Field.Rec")
                local tv = ir.Value.LocalVar(dst)
                local kv = ir.Value.String(field.name)
                local vv = self:exp_to_value(cmds, field.exp)
                local src_typ = field.exp._type
                local cmd = ir.Cmd.SetTable(loc, src_typ, tv, kv, vv)
                table.insert(cmds, cmd)
            end

        elseif typ._tag == "types.T.Record" then
            local field_exps = {}
            for _, field in ipairs(exp.fields) do
                field_exps[field.name] = field.exp
            end

            table.insert(cmds, ir.Cmd.NewRecord(loc, typ, dst))
            table.insert(cmds, ir.Cmd.CheckGC())
            for _, field_name in ipairs(typ.field_names) do
                local f_exp = assert(field_exps[field_name])
                local dv = ir.Value.LocalVar(dst)
                local vv = self:exp_to_value(cmds, f_exp)
                table.insert(cmds, ir.Cmd.SetField(exp.loc, typ, dv, field_name, vv))
            end
        elseif typ._tag == "types.T.Module" then
            -- Fallthrough to default

        else
            typedecl.tag_error(typ._tag)
        end

    elseif tag == "ast.Exp.Lambda" then
        local f_id = self:register_lambda(exp, "$lambda")
        local func = self.module.functions[f_id]
        self:convert_func(exp)
        ir.add_exported_function(self.module, f_id)

        local upvalues = {}
        for _, upval_info in ipairs(func.captured_vars) do
            table.insert(upvalues, upval_info.value)
        end

        table.insert(cmds, ir.Cmd.NewClosure(exp.loc, dst, upvalues, f_id))

    elseif tag == "ast.Exp.ExtraRet" then
        assert(self.dsts_of_call[exp.call_exp])
        self.dsts_of_call[exp.call_exp][exp.i] = dst

    elseif tag == "ast.Exp.CallFunc" then

        local f_typ = exp.exp._type
        local def = (
            exp.exp._tag == "ast.Exp.Var" and
            exp.exp.var._tag == "ast.Var.Name" and
            exp.exp.var._def )

        -- Prepare the list of destination variables.
        -- If this is a function with multiple return values then dsts[2]..dsts[N] will be
        -- initialized later, by ExtraRet.
        assert(not self.dsts_of_call[exp])
        local dsts = {}
        for i = 1, #exp._types do
            dsts[i] = false
        end
        if dst then
            dsts[1] = dst
        end
        table.insert(self.call_exps, exp)
        self.dsts_of_call[exp] = dsts

        -- Evaluate the function call expression
        local mod_name = exp.exp.var._mod_name
        local f_val
        if  def and (
                def._tag == "checker.Def.Builtin" or
                def._tag == "checker.Def.Function") and
                not mod_name then
            f_val = false
        else
            f_val = self:exp_to_value(cmds, exp.exp)
        end

        -- Evaluate the function arguments
        local xs = {}
        for i, arg_exp in ipairs(exp.args) do
            xs[i] = self:exp_to_value(cmds, arg_exp)
        end

        -- Generate the function call command
        if     def and def._tag == "checker.Def.Builtin" then
            local bname = def.id
            if     bname == "io.write" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinIoWrite(loc, xs))
            elseif bname == "math.sqrt" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinMathSqrt(loc, dsts, xs))
            elseif bname == "string.char" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinStringChar(loc, dsts, xs))
                table.insert(cmds, ir.Cmd.CheckGC())
            elseif bname == "string.sub" then
                assert(#xs == 3)
                table.insert(cmds, ir.Cmd.BuiltinStringSub(loc, dsts, xs))
                table.insert(cmds, ir.Cmd.CheckGC())
            elseif bname == "type" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinType(loc, dsts, xs))
            elseif bname == "tostring" then
                assert(#xs == 1)
                table.insert(cmds, ir.Cmd.BuiltinTostring(loc, dsts, xs))
            else
                typedecl.tag_error(bname)
            end

        elseif def and def._tag == "checker.Def.Function" then
            if mod_name then
                if not self.module.imported_functions[def.stat.name] then
                    f_val.is_imported = true
                end
                table.insert(cmds, ir.Cmd.CallDyn(loc, f_typ, dsts, f_val, xs))
            else
                local f_id = assert(self.fun_id_of_exp[def.stat.value])
                table.insert(cmds, ir.Cmd.CallStatic(loc, f_typ, dsts, f_id, xs))
            end

        else
            table.insert(cmds, ir.Cmd.CallDyn(loc, f_typ, dsts, f_val, xs))
        end

    elseif tag == "ast.Exp.CallMethod" then
        error("not implemented")

    elseif tag == "ast.Exp.Var" then
        local var = exp.var
        if     var._tag == "ast.Var.Name" then
            local def = var._def
            if def._tag == "checker.Def.Variable" then
                local var_info = self:resolve_variable(def.decl)

                if var_info._tag == "to_ir.Var.LocalVar" or var_info._tag == "to_ir.Var.Upvalue" then
                    use_exp_to_value = true
                elseif var_info._tag == "to_ir.Var.GlobalVar" then
                    table.insert(cmds, ir.Cmd.GetGlobal(loc, dst, var_info.id))
                else
                    typedecl.tag_error(var_info._tag)
                end
            else
                use_exp_to_value = true
            end

        elseif var._tag == "ast.Var.Bracket" then
            local arr = self:exp_to_value(cmds, var.t)
            local i   = self:exp_to_value(cmds, var.k)
            local dst_typ = var._type
            table.insert(cmds, ir.Cmd.GetArr(loc, dst_typ, dst, arr, i))

        elseif var._tag == "ast.Var.Dot" then
              local typ = assert(var.exp._type)
              local field = var.name
              local cmd
              local rec = self:exp_to_value(cmds, var.exp)
              if     typ._tag == "types.T.Table" then
                  local key = ir.Value.String(field)
                  local dst_typ = typ.fields[field]
                  cmd = ir.Cmd.GetTable(loc, dst_typ, dst, rec, key)
              elseif typ._tag == "types.T.Record" then
                  cmd = ir.Cmd.GetField(loc, typ, dst, rec, field)
              else
                  typedecl.tag_error(typ._tag)
              end

              table.insert(cmds, cmd)

        else
            typedecl.tag_error(var._tag)
        end

    elseif tag == "ast.Exp.Unop" then
        local op = exp.op
        if op == "not" then
            local e = self:exp_to_value(cmds, exp.exp)
            local v = self:value_is_truthy(cmds, exp.exp, e)
            table.insert(cmds, ir.Cmd.Unop(loc, dst, "BoolNot", v))
        else
            local irop = type_specific_unop(op, exp.exp._type)
            local v = self:exp_to_value(cmds, exp.exp)
            table.insert(cmds, ir.Cmd.Unop(loc, dst, irop, v))
        end

    elseif tag == "ast.Exp.Concat" then
        local xs = {}
        for i, x_exp in ipairs(exp.exps) do
            xs[i] = self:exp_to_value(cmds, x_exp)
        end
        table.insert(cmds, ir.Cmd.Concat(loc, dst, xs))
        table.insert(cmds, ir.Cmd.CheckGC())

    elseif tag == "ast.Exp.Binop" then
        local op = exp.op
        if     op == "and" then
            self:exp_to_assignment(cmds, dst, exp.lhs)
            local v = ir.Value.LocalVar(dst)
            local condBool = self:value_is_truthy(cmds, exp.lhs, v)
            local rhs_cmds = {}
            self:exp_to_assignment(rhs_cmds, dst, exp.rhs)
            table.insert(cmds, ir.Cmd.If(exp.loc,
                condBool,
                ir.Cmd.Seq(rhs_cmds),
                ir.Cmd.Seq({})))

        elseif op == "or" then
            self:exp_to_assignment(cmds, dst, exp.lhs)
            local v = ir.Value.LocalVar(dst)
            local condBool = self:value_is_truthy(cmds, exp.lhs, v)
            local rhs_cmds = {}
            self:exp_to_assignment(rhs_cmds, dst, exp.rhs)
            table.insert(cmds, ir.Cmd.If(exp.loc,
                condBool,
                ir.Cmd.Seq({}),
                ir.Cmd.Seq(rhs_cmds)))

        elseif op == ".." then
            -- Flatten (a .. (b .. (c .. d))) into (a .. b .. c .. d)
            local xs = {}
            while exp._tag == "ast.Exp.Binop" and exp.op == ".." do
                table.insert(xs, self:exp_to_value(cmds, exp.lhs))
                exp = exp.rhs
            end
            table.insert(xs, self:exp_to_value(cmds, exp))

            table.insert(cmds, ir.Cmd.Concat(loc, dst, xs))

        else
            local irop = type_specific_binop(op, exp.lhs._type, exp.rhs._type)
            local v1 = self:exp_to_value(cmds, exp.lhs)
            local v2 = self:exp_to_value(cmds, exp.rhs)
            table.insert(cmds, ir.Cmd.Binop(loc, dst, irop, v1, v2))
        end

    elseif tag == "ast.Exp.Cast" then
        local dst_typ = exp._type
        local src_typ = exp.exp._type
        if src_typ._tag == dst_typ._tag then
            -- Do-nothing cast
            self:exp_to_assignment(cmds, dst, exp.exp)
        else
            local v = self:exp_to_value(cmds, exp.exp)
            if     dst_typ._tag == "types.T.Any" then
                table.insert(cmds, ir.Cmd.ToDyn(loc, src_typ, dst, v))
            elseif src_typ._tag == "types.T.Any" then
                table.insert(cmds, ir.Cmd.FromDyn(loc, dst_typ, dst, v))
            else
                error(string.format("error casting from type '%s' to '%s'",
                        types.tostring(src_typ), types.tostring(dst_typ)))
            end
        end

    elseif tag == "ast.Exp.ToFloat" then
        local v = self:exp_to_value(cmds, exp.exp)
        table.insert(cmds, ir.Cmd.ToFloat(loc, dst, v))

    else
        use_exp_to_value = true
    end

    if use_exp_to_value then
        local value = self:exp_to_value(cmds, exp, true)
        table.insert(cmds, ir.Cmd.Move(loc, dst, value))
    end
end

-- Returns a boolean value corresponding to whether exp is truthy.
-- As usual, may add intermediate cmds to the @cmds list
function ToIR:value_is_truthy(cmds, exp, val)
    local typ = exp._type
    if typ._tag == "types.T.Boolean" then
        return val
    elseif typ._tag == "types.T.Any" then
        local b = ir.add_local(self.func, false, types.T.Boolean())
        table.insert(cmds, ir.Cmd.IsTruthy(exp.loc, b, val))
        return ir.Value.LocalVar(b)
    elseif typedecl.tag_is_type(typ) then
        typedecl.tag_error(typ._tag, "unable to test this type for truthiness.")
    else
        typedecl.tag_error(typ._tag)
    end
end

function ToIR:new_local_from_decl(decl)
    local v = ir.add_local(self.func, decl.name, decl._type)
    self.loc_id_of_decl[decl] = v
    return v
end

return to_ir
