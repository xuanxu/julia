using Core.Compiler: method_instances, retrieve_code_info, CodeInfo,
    MethodInstance, SSAValue, GotoNode, Slot, SlotNumber
using Base.Meta: isexpr
using Test

struct Ctx; end

# A no-op cassette-like transform
function transform_expr(expr, map_slot_number, map_ssa_value)
    transform(expr) = transform_expr(expr, map_slot_number, map_ssa_value)
    if isexpr(expr, :call)
        return Expr(:call, overdub, SlotNumber(1), map(transform, expr.args)...)
    elseif isexpr(expr, :gotoifnot)
        return Expr(:gotoifnot, transform(expr), map_ssa_value(SSAValue(expr.args[2])).id)
    elseif isa(expr, GotoNode)
        return GotoNode(map_ssa_value(SSAValue(expr.label)).id)
    elseif isa(expr, Slot)
        return map_slot_number(expr.id)
    elseif isa(expr, SSAValue)
        return map_ssa_value(expr)
    else
        return expr
    end
end

function transform!(ci, nargs)
    code = ci.code
    ci.slotnames = Symbol[Symbol("#self#"), :ctx, :f, :args, ci.slotnames[nargs+1:end]...]
    ci.slotflags = UInt8[(0x00 for i = 1:4)..., ci.slotflags[nargs+1:end]...]
    # Insert one SSAValue for every argument statement
    for i = 1:nargs
        pushfirst!(code, Expr(:getfield, SlotNumber(3), i))
    end
    function map_slot_number(slot)
        if slot == 1
            # self in the original function is now `f`
            return SlotNumber(3)
        elseif 2 <= slot <= nargs + 1
            # Arguments get inserted as ssa values at the top of the function
            return SSAValue(slot - 2)
        else
            # The first non-argument slot will be 5
            return SlotNumber(slot - (nargs + 1) + 4)
        end
    end
    map_ssa_value(ssa::SSAValue) = SSAValue(ssa.id + nargs)
    for i = (nargs+1:length(code))
        code[i] = transform_expr(code[i], map_slot_number, map_ssa_value)
    end
end

function overdub_generator(self, c, f, args)
    mis = method_instances(f.instance, args)
    @assert length(mis) == 1
    mi = mis[1]
    # Unsupported in this mini-cassette
    @assert !mi.def.isva
    code_info = retrieve_code_info(mi)
    @assert isa(code_info, CodeInfo)
    code_info = copy(code_info)
    if isdefined(code_info, :edges)
        code_info.edges = MethodInstance[mi]
    end
    transform!(code_info, length(args))
    code_info
end

@eval function overdub(c::Ctx, f, args...)
    $(Expr(:meta, :generated_only))
    $(Expr(:meta,
            :generated,
            Expr(:new,
                Core.GeneratedFunctionStub,
                :overdub_generator,
                Any[:overdub, :ctx, :f, :args],
                Any[],
                @__LINE__,
                QuoteNode(Symbol(@__FILE__)),
                true)))
end

f() = 1
@test overdub(Ctx(), f) === 1
f() = 2
@test overdub(Ctx(), f) === 2
