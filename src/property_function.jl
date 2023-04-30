# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


# Modeled after Base.Base._lift_one_interp!:
function subst_prop_refs!(e)
    argmap = IdDict{Symbol,Symbol}()  # store the new gensymed arguments
    subst_prop_refs_helper(e, false, argmap) # Start out _not_ in a quote context (false)
    argmap
end

subst_prop_refs_helper(v, _, _) = v

function subst_prop_refs_helper(expr::Expr, in_quote_context, argmap)
    if expr.head === :$
        if in_quote_context  # This $ is simply interpolating out of the quote
            # Now, we're out of the quote, so any _further_ $ is ours.
            in_quote_context = false
        else
            propname = expr.args[1]
            if propname isa Symbol
                if !haskey(argmap, propname)
                    argmap[propname] = gensym(propname)
                end
                return argmap[propname]
            else
                throw(ArgumentError("Properties referenced via \$... must by symbols"))
            end
        end
    elseif expr.head === :quote
        in_quote_context = true   # Don't try to lift $ directly out of quotes
    elseif expr.head === :macrocall
        return expr  # Don't recur into macro calls, since some other macros use $
    end
    for (i,e) in enumerate(expr.args)
        expr.args[i] = subst_prop_refs_helper(e, in_quote_context, argmap)
    end
    expr
end


"""
    struct PropertyFunction <: Function

Use only for dispatch in special cases. User code should *not* create
instances of `PropertyFunction` directly - use the `@fp` macro instead.

The type parameters of `PropertyFunction` are subject to change and not
part of the public API of the PropertyFunctions package.
"""
struct PropertyFunction{FK<:Function,FA<:Function} <: Function
    kernel_func::FK
    accessor_func::FA
end

"""
    @pf expression

Generates a function that accesses the properties of it's argument
referenced via `\$property` in `expression`.

`@pf(\$a + \$c^2)` is equivalent to `x -> x.a + x.c^2`.

Examples:

```julia
xs = StructArrays.StructArray((
    a = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6],
    b = [0.1, 0.5, 0.9, 0.9, 0.9, 0.6, 0.1, 0.9, 0.8, 0.2],
    c = [0.4, 0.1, 0.4, 0.1, 0.9, 0.2, 0.4, 0.8, 0.0, 0.1]
))

@pf(\$a + \$c^2)(xs[1])
xs .|> @pf \$a + \$c^2
```

Broadcasting specializations try to ensure that only the columns referenced
via `\$colname` in `expr` will be read, reducing memory traffic. So `data.b`
will not be accessed in the example above.

`@pf` is also very handy in `sortby` and `filterby`:

```julia
xs |> sortby(@pf \$a + \$c^2)
xs |> filterby(@pf \$a + \$c^2 < 0.5)
```
"""
macro pf(expr)
    argmap = subst_prop_refs!(expr)

    props = collect(keys(argmap))
    args = [esc(argmap[p]) for p in props]

    propacc = map(p -> :(obj.$p), props)

    res_expr  = quote
        local kernel_func
        @inline kernel_func($(args...)) = $(esc(expr))
        local accessor_func
        @inline accessor_func(obj) = ($(propacc...),)

        PropertyFunction(kernel_func, accessor_func)
    end

    res_expr
end
export @pf


(pf::PropertyFunction)(x) = pf.kernel_func(pf.accessor_func(x)...)

# ToDo - necessary?
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(tbl) =
#    broadcast(bpf.f.kernel_func, bpf.f.accessor_func(tbl)...)

_colaccess(xs) = Val(Tables.columnaccess(xs))

@inline function Broadcast.broadcasted(pf::PropertyFunction, xs::AbstractArray)
    _broadcasted_impl(_colaccess(xs), pf, xs)
end

@inline function _broadcasted_impl(::Val{true}, pf::PropertyFunction, xs::AbstractArray)
    Broadcast.broadcasted(pf.kernel_func, pf.accessor_func(Tables.columns(xs))...)
end

@inline function _broadcasted_impl(::Val{false}, pf::PropertyFunction, xs::AbstractArray)
    Broadcast.broadcasted(x -> pf.kernel_func(pf.accessor_func(x)...), xs)
end

# DoTo: Specialize broadcasting for Iterators.Flatten over objects with column access

# DoTo - possible extensions:

# Strided.StridedView offers automatic multithreaded operation.
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{StridedView}, tbl) =
#    broadcast(bpf.f.kernel_func, map(StridedView, bpf.f.accessor_func(tbl))...)

#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{LazyArray}, tbl) =
#    LazyArray(Broadcast.broadcasted(bpf.f, tbl))