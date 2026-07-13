# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


# A property reference: a property name or a path of nested property names.
const _PropRef = Union{Symbol, Tuple{Vararg{Symbol}}}

_propref(path::Tuple{Vararg{Symbol}}) = length(path) == 1 ? only(path) : path

_ref_name(name::Symbol) = name
_ref_name(path::Tuple) = Symbol(join(path, "."))

_ref_trgname(name::Symbol) = name
_ref_trgname(path::Tuple) = last(path)


# Property path of expressions like `a.b.c`:
_sym_path(sym::Symbol) = (sym,)
_sym_path(::Any) = nothing
function _sym_path(expr::Expr)
    if expr.head === :. && length(expr.args) == 2 && expr.args[2] isa QuoteNode && expr.args[2].value isa Symbol
        base = _sym_path(expr.args[1])
        isnothing(base) ? nothing : (base..., expr.args[2].value::Symbol)
    else
        nothing
    end
end

# Property path of expressions like `$a.b.c` and `$(a.b.c)`:
_dollar_path(::Any) = nothing
function _dollar_path(expr::Expr)
    if expr.head === :$ && length(expr.args) == 1
        _sym_path(only(expr.args))
    elseif expr.head === :. && length(expr.args) == 2 && expr.args[2] isa QuoteNode && expr.args[2].value isa Symbol
        base = _dollar_path(expr.args[1])
        isnothing(base) ? nothing : (base..., expr.args[2].value::Symbol)
    else
        nothing
    end
end


# Modeled after Base.Base._lift_one_interp!:
function subst_prop_refs!(e)
    argmap = Pair{_PropRef,Symbol}[]  # maps property references to gensymed arguments, in order of first use
    subst_prop_refs_helper(e, false, argmap) # Start out _not_ in a quote context (false)
    argmap
end

function _get_argsym!(argmap::Vector{Pair{_PropRef,Symbol}}, propref::_PropRef)
    i = findfirst(entry -> entry.first == propref, argmap)
    if isnothing(i)
        push!(argmap, propref => gensym(_ref_name(propref)))
        i = lastindex(argmap)
    end
    argmap[i].second
end

subst_prop_refs_helper(v, _, _) = v

function subst_prop_refs_helper(expr::Expr, in_quote_context, argmap)
    if !in_quote_context
        path = _dollar_path(expr)
        if !isnothing(path)
            return _get_argsym!(argmap, _propref(path))
        end
    end
    if expr.head === :$
        if in_quote_context  # This $ is simply interpolating out of the quote
            # Now, we're out of the quote, so any _further_ $ is ours.
            in_quote_context = false
        else
            throw(ArgumentError("Properties referenced via \$... must be symbols or property paths like \$(a.b.c)"))
        end
    elseif expr.head === :quote
        in_quote_context = true   # Don't try to lift $ directly out of quotes
    elseif expr.head === :macrocall
        return expr  # Don't recur into macro calls, since some other macros use $
    end
    in_params = expr.head === :parameters
    for (i,e) in enumerate(expr.args)
        new_e = subst_prop_refs_helper(e, in_quote_context, argmap)
        if in_params && new_e isa Symbol && e isa Expr
            path = _dollar_path(e)
            if !isnothing(path)
                # Preserve the property name of `$prop` in named-tuple/kwarg shorthand position:
                new_e = Expr(:kw, last(path), new_e)
            end
        end
        expr.args[i] = new_e
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

    props = [entry.first for entry in argmap]
    vars = [entry.second for entry in argmap]

    return props, vars, new_expr
end


"""
    struct PropertyFunction <: Function

Use only for dispatch in special cases. User code should *not* create
instances of `PropertyFunction` directly - use the [`@pf`](@ref) or
[`@fp`](@ref) macros instead.

The type parameters of `PropertyFunction` are subject to change and not
part of the public API of the PropertyFunctions package.
"""
struct PropertyFunction{names, F<:Function} <: Function
    sel_prop_func::F
end
export PropertyFunction

PropertyFunction{names}(sel_prop_func::F) where {names,F<:Function} = PropertyFunction{names,F}(sel_prop_func)

(pf::PropertyFunction)(x) = pf.sel_prop_func(_prop_tuple(pf, x)...)

_getprop_expr(base, name::Symbol) = Expr(:., base, QuoteNode(name))
_getprop_expr(base, path::Tuple) = foldl((e, name) -> Expr(:., e, QuoteNode(name)), path, init = base)

@generated function _prop_tuple(pf::PropertyFunction{names}, obj) where names
    expr = :(())
    for ref in names
        push!(expr.args, _getprop_expr(:obj, ref))
    end
    return expr
end


"""
    PropertyFunctions.subcolumn(col::AbstractArray, name::Symbol)

Get the column `name` of an array `col` of structs.

Returns `getproperty.(col, name)` by default, `StructArray` columns
provide zero-copy access. Specialize for array types that support
efficient column access.
"""
@inline subcolumn(col::AbstractArray, name::Symbol) = getproperty.(col, name)
@inline subcolumn(col::StructArray, name::Symbol) = getproperty(col, name)

_getcol_expr(base, name::Symbol) = Expr(:., base, QuoteNode(name))
function _getcol_expr(base, path::Tuple)
    ref = Expr(:., base, QuoteNode(first(path)))
    for name in Base.tail(path)
        ref = :(subcolumn($ref, $(QuoteNode(name))))
    end
    return ref
end

@generated function _prop_cols(pf::PropertyFunction{names}, cols) where names
    expr = :(())
    for ref in names
        push!(expr.args, _getcol_expr(:cols, ref))
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

Source names may also be paths of nested property names, e.g. in
`@pf (;\$(a.b))`.

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

Generates a function that accesses the properties of its argument
referenced via `\$property` in `expression`.

`@pf(\$a + \$c^2)` is equivalent to `x -> x.a + x.c^2`.

Nested properties can be referenced via `\$a.b.c` or `\$(a.b.c)`, and
broadcasting will read only the required nested columns (see
[`PropertyFunctions.subcolumn`](@ref)).

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
    _pf_impl(expr)
end
export @pf

function _pf_impl(expr)
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


"""
    @fp expression

Like [`@pf`](@ref), but with the inverse `\$` convention: plain symbols in
value positions refer to properties of the function argument, while
`\$`-escaped symbols and expressions refer to the surrounding scope.
Function names and other non-value positions are never treated as
properties.

`@fp(a + f(b) + \$c)` is equivalent to `@pf(\$a + f(\$b) + c)`.

Nested properties are referenced via plain `a.b.c` chains.

Note that functions passed as *arguments* are in value position and so
must be `\$`-escaped: `@fp foldl(\$+, a)`.
"""
macro fp(expr)
    _pf_impl(_flip_dollars(expr))
end
export @fp

_flip_dollars(x) = x
_flip_dollars(sym::Symbol) = Expr(:$, sym)

_is_dotcall_argtuple(x) = x isa Expr && x.head === :tuple

function _flip_dollars(expr::Expr)
    if expr.head === :$ && length(expr.args) == 1
        return only(expr.args)
    elseif expr.head === :quote || expr.head === :macrocall
        return expr
    elseif expr.head === :call || expr.head === :kw || expr.head === :(::) ||
            (expr.head === :. && length(expr.args) == 2 && _is_dotcall_argtuple(expr.args[2]))
        # Callees (incl. broadcast callees), keyword-argument names and type
        # annotations are not value positions:
        return Expr(expr.head, expr.args[1], map(_flip_dollars, expr.args[2:end])...)
    else
        return Expr(expr.head, map(_flip_dollars, expr.args)...)
    end
end

function _unpack_dollar_ref(expr)
    path = _dollar_path(expr)
    isnothing(path) ? nothing : _propref(path)
end

_unpack_ntelem_assignment(::Any) = nothing
function _unpack_ntelem_assignment(expr::Expr)
    if expr.head == :kw
        src = _unpack_dollar_ref(expr.args[2])
        if !isnothing(src) && expr.args[1] isa Symbol
            return expr.args[1]::Symbol => src
        else
            return nothing
        end
    else
        src = _unpack_dollar_ref(expr)
        if !isnothing(src)
            return _ref_trgname(src) => src
        else
            return nothing
        end
    end
end

_get_property_selection(::Any) = nothing
function _get_property_selection(expr::Expr)
    inputs = _PropRef[]
    output = Symbol[]
    if expr.head == :tuple && length(expr.args) == 1
        inner_expr = only(expr.args)
        if inner_expr isa Expr && inner_expr.head == :parameters
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

# A property function that references no properties has no columns to broadcast over:
@inline Broadcast.broadcasted(pf::PropertyFunction{()}, xs::AbstractArray) =
    _broadcasted_impl(Val(false), pf, xs)

@inline function _broadcasted_impl(::Val{true}, pf::PropertyFunction, xs::AbstractArray)
    cols = _prop_cols(pf, Tables.columns(xs))
    bstyle = BroadcastStyle(typeof(StructArray(cols)))
    Broadcast.broadcasted(bstyle, pf.sel_prop_func, cols...)
end

@inline function _broadcasted_impl(::Val{true}, pf::PropSelFunction{src_names,trg_names}, xs::AbstractArray) where {src_names,trg_names}
    cols = _prop_cols(pf, Tables.columns(xs))
    named_cols = NamedTuple{trg_names}(cols)
    ctor = Tables.materializer(xs)
    return ctor(named_cols)
end

@inline function _broadcasted_impl(::Val{false}, pf::PropertyFunction, xs::AbstractArray)
    # ToDo: Use StructArray broadcast style here as well.
    Broadcast.broadcasted(x -> pf.sel_prop_func(_prop_tuple(pf, x)...), xs)
end

# Wider signatures would be ambiguous with Base and LinearAlgebra methods;
# other array shapes fall back to the generic Base implementations:
Base.map(pf::PropertyFunction, xs::AbstractVector) = broadcast(pf, xs)
Base.filter(pf::PropertyFunction, xs::AbstractVector) = filterby(pf)(xs)
Base.filter(pf::PropertyFunction, xs::Vector) = filterby(pf)(xs)
Base.filter(pf::PropertyFunction, xs::BitVector) = filterby(pf)(xs)


# ToDo: Specialize broadcasting for Iterators.Flatten over objects with column access

# ToDo - possible extensions:

# Strided.StridedView offers automatic multithreaded operation.
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{StridedView}, tbl) =
#    broadcast(bpf.f.sel_prop_func, map(StridedView, _prop_tuple(bpf.f, tbl))...)

#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{LazyArray}, tbl) =
#    LazyArray(Broadcast.broadcasted(bpf.f, tbl))
