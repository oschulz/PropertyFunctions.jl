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
    props2varsyms(expr)

Replace `\$`-escaped properties in `expr` by generated variable names
and return the original property names, new argument names and the modified
expression.

Usage:

```julia
props, vars, new_expr = props2varsyms(expr)
```
"""
function props2varsyms(exr)
    new_expr = deepcopy(exr)
    argmap = subst_prop_refs!(new_expr)

    props = collect(keys(argmap))
    vars = [argmap[p] for p in props]

    return props, vars, new_expr
end


"""
    struct PropertyFunction <: Function

Use only for dispatch in special cases. User code should *not* create
instances of `PropertyFunction` directly - use the `@fp` macro instead.

The type parameters of `PropertyFunction` are subject to change and not
part of the public API of the PropertyFunctions package.
"""
struct PropertyFunction{names, F<:Function} <: Function
    sel_prop_func::F
end
export PropertyFunction

PropertyFunction{names}(sel_prop_func::F) where {names,F<:Function} = PropertyFunction{names,F}(sel_prop_func)

(pf::PropertyFunction)(x) = pf.sel_prop_func(_prop_tuple(pf, x)...)

@generated function _prop_tuple(pf::PropertyFunction{names}, obj) where names
    expr = :(())
    for nm in names
        push!(expr.args, :(obj.$nm))
    end
    return expr
end



struct _NamedTupleCtor{names} <: Function end
(::_NamedTupleCtor{names})(xs...) where names = NamedTuple{names}(xs)

"""
    PropSelFunction{src_names,trg_names} <: PropertyFunction

A special kind of `PropertyFunction` that selects (and possibly renames)
properties, but does no other computations.

A PropSelFunction can be constructed via the [`@pf`](@ref) macro

```julia
propsel = @pf (;\$c, d = \$a)
```

or directly via

```julia
propsel = PropSelFunction(:c, :a => :d)
```

or

```julia
propsel = PropSelFunction{(:c, :a), (:c, :d)}()
```

or just

```julia
PropSelFunction{(:c, :a)}()
```

if no property name mapping is required.

See also [`@pf`](@ref).
"""
const PropSelFunction{src_names, trg_names} = PropertyFunctions.PropertyFunction{src_names, PropertyFunctions._NamedTupleCtor{trg_names}}
export PropSelFunction

PropSelFunction{src_names,trg_names}() where {src_names,trg_names} = PropertyFunction{src_names}(_NamedTupleCtor{trg_names}())
PropSelFunction{src_names}() where {src_names} = PropSelFunction{src_names, src_names}()

function PropSelFunction(selects::Union{Symbol,Pair{Symbol,Symbol}}...)
    src_names = map(_propsel_src, selects)
    trg_names = map(_propsel_trg, selects)
    PropSelFunction{src_names, trg_names}()
end

_propsel_src(s::Symbol) = s
_propsel_trg(s::Symbol) = s
_propsel_src(src_trg::Pair{Symbol,Symbol}) = src_trg[1]
_propsel_trg(src_trg::Pair{Symbol,Symbol}) = src_trg[2]



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

Functions generated by `@pf` come with broadcasting specializations that try
to ensure that only the columns referenced via `\$colname` in `expr` will be
read, reducing memory traffic. So `data.b` will not be accessed in the
example above. If the broadcasted function generates structs (including
`NamedTuple`s), broadcasting specialization will try to return a
`StructArrays.StructArray`.

Property functions of the kind

```julia
propsel = @pf (;\$c, d = \$a)
```

Can be used to select (and rename) properties, and they have special
broadcasting optimizations for table-like arguments. This can make
broadcasts of such property selectors zero-copy O(1) operations:

```
new_xs = propsel.(xs)
new_xs.c === xs.c
new_xs.d === xs.a
```

`@pf` is also very handy in `sortby` and `filterby`:

```julia
xs |> sortby(@pf \$a + \$c^2)
xs |> filterby(@pf \$a + \$c^2 < 0.5)
```
"""
macro pf(expr)
    srcs_trgs = _get_property_selection(expr)
    if !isnothing(srcs_trgs)
        srcs, trgs = srcs_trgs
        return :(PropSelFunction{$(Expr(:tuple, QuoteNode.(srcs)...)), $(Expr(:tuple, QuoteNode.(trgs)...))}())
    else
        props, args, arg_expr = props2varsyms(expr)
        esc_args = esc.(args)

        names_expr = :(())
        append!(names_expr.args, map(QuoteNode, props))

        res_expr = quote
            local sel_prop_func
            @inline sel_prop_func($(esc_args...)) = $(esc(arg_expr))

            PropertyFunction{$names_expr}(sel_prop_func)
        end

        return res_expr
    end
end
export @pf

function _unpack_dollar_sym(expr::Expr)
    if expr.head == :$ && length(expr.args) == 1
        return only(expr.args)
    else
        return nothing
    end
end

function _unpack_ntelem_assignment(expr::Expr)
    if expr isa Expr && expr.head == :kw
        src = _unpack_dollar_sym(expr.args[2])
        if !isnothing(src)
            return expr.args[1] => src
        else
            return nothing
        end
    else
        src = _unpack_dollar_sym(expr)
        if !isnothing(src)
            return src => src
        else
            return nothing
        end
    end
end

_get_property_selection(::Any) = nothing
function _get_property_selection(expr::Expr)
    inputs = Symbol[]
    output = Symbol[]
    if expr.head == :tuple && length(expr.args) == 1
        inner_expr = only(expr.args)
        if inner_expr.head == :parameters
            for arg in inner_expr.args
                src_trg = _unpack_ntelem_assignment(arg)
                if isnothing(src_trg)
                    return nothing
                else
                    push!(output, src_trg[1])
                    push!(inputs, src_trg[2])
                end
            end
            return inputs => output
        else
            return nothing
        end
    else
        return nothing
    end
end



# ToDo - necessary?
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(tbl) =
#    broadcast(bpf.f.sel_prop_func, _prop_tuple(bpf.f, tbl)...)

_colaccess(xs) = Val(Tables.columnaccess(xs))

@inline function Broadcast.broadcasted(pf::PropertyFunction, xs::AbstractArray)
    _broadcasted_impl(_colaccess(xs), pf, xs)
end

@inline function _broadcasted_impl(::Val{true}, pf::PropertyFunction, xs::AbstractArray)
    cols = _prop_tuple(pf, Tables.columns(xs))
    bstyle = BroadcastStyle(typeof(StructArray(cols)))
    Broadcast.broadcasted(bstyle, pf.sel_prop_func, cols...)
end

@inline function _broadcasted_impl(::Val{true}, pf::PropSelFunction{src_names,trg_names}, xs::AbstractArray) where {src_names,trg_names}
    cols = _prop_tuple(pf, Tables.columns(xs))
    named_cols = NamedTuple{trg_names}(cols)
    ctor = Tables.materializer(xs)
    return ctor(named_cols)
end

@inline function _broadcasted_impl(::Val{false}, pf::PropertyFunction, xs::AbstractArray)
    # ToDo: Use StructArray broadcast style here as well.
    Broadcast.broadcasted(x -> pf.sel_prop_func(_prop_tuple(pf, x)...), xs)
end

# DoTo: Specialize broadcasting for Iterators.Flatten over objects with column access

# DoTo - possible extensions:

# Strided.StridedView offers automatic multithreaded operation.
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{StridedView}, tbl) =
#    broadcast(bpf.f.sel_prop_func, map(StridedView, _prop_tuple(bpf.f, tbl))...)

#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{LazyArray}, tbl) =
#    LazyArray(Broadcast.broadcasted(bpf.f, tbl))
