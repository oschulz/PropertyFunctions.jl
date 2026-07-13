# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


# A property reference: a property name or a path of nested property names.
const _PropRef = Union{Symbol, Tuple{Vararg{Symbol}}}

_propref(path::Tuple{Vararg{Symbol}}) = length(path) == 1 ? only(path) : path

_ref_head(name::Symbol) = name
_ref_head(path::Tuple) = first(path)

_ref_trgname(name::Symbol) = name
_ref_trgname(path::Tuple) = last(path)

_is_prefix_of(::_PropRef, ::Symbol) = false
_is_prefix_of(a::Symbol, b::Tuple) = first(b) === a
_is_prefix_of(a::Tuple, b::Tuple) = length(a) < length(b) && a === b[1:length(a)]

# Drop references that are covered by a reference to a parent property:
_merge_proprefs(refs::Vector{_PropRef}) =
    filter(ref -> !any(other -> _is_prefix_of(other, ref), refs), refs)


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


"""
    subst_prop_refs(expr)

Replace `\$`-escaped property references in `expr` by property accesses on a
generated argument name and return the referenced properties, the argument
name and the modified expression.

Usage:

```julia
props, argsym, new_expr = subst_prop_refs(expr)
```
"""
function subst_prop_refs(expr)
    refs = _PropRef[]  # referenced properties, in order of first use
    argsym = gensym(:x)
    new_expr = subst_prop_refs_helper(deepcopy(expr), false, refs, argsym) # Start out _not_ in a quote context (false)
    return _merge_proprefs(refs), argsym, new_expr
end

# Modeled after Base.Base._lift_one_interp!:
subst_prop_refs_helper(v, _, _, _) = v

function subst_prop_refs_helper(expr::Expr, in_quote_context, refs, argsym)
    if !in_quote_context
        path = _dollar_path(expr)
        if !isnothing(path)
            ref = _propref(path)
            ref in refs || push!(refs, ref)
            return _getprop_expr(argsym, ref)
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
        path = in_quote_context ? nothing : _dollar_path(e)
        new_e = subst_prop_refs_helper(e, in_quote_context, refs, argsym)
        if in_params && !isnothing(path)
            # Preserve the property name of `$prop` in named-tuple/kwarg shorthand position:
            new_e = Expr(:kw, last(path), new_e)
        end
        expr.args[i] = new_e
    end
    expr
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

(pf::PropertyFunction)(x) = pf.sel_prop_func(x)

_getprop_expr(base, name::Symbol) = Expr(:., base, QuoteNode(name))
_getprop_expr(base, path::Tuple) = foldl((e, name) -> Expr(:., e, QuoteNode(name)), path, init = base)


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


# Broadcast kernel that assembles the referenced properties into a (possibly
# nested) NamedTuple and passes it to the wrapped function as a single argument:
struct _PropsNTKernel{names,F<:Function} <: Function
    sel_prop_func::F
end

_PropsNTKernel(pf::PropertyFunction{names,F}) where {names,F} = _PropsNTKernel{names,F}(pf.sel_prop_func)

@inline (k::_PropsNTKernel)(args...) = k.sel_prop_func(_props_nt(k, args))

function _props_nt_expr(refs::Vector, argexprs::Vector)
    ks = Symbol[]
    vs = Any[]
    for ref in refs
        head = _ref_head(ref)
        head in ks && continue
        push!(ks, head)
        idxs = findall(r -> _ref_head(r) === head, refs)
        if length(idxs) == 1 && refs[only(idxs)] isa Symbol
            push!(vs, argexprs[only(idxs)])
        else
            subrefs = Any[_propref(Base.tail(refs[i]::Tuple{Vararg{Symbol}})) for i in idxs]
            push!(vs, _props_nt_expr(subrefs, argexprs[idxs]))
        end
    end
    return :(NamedTuple{$(QuoteNode((ks...,)))}(($(vs...),)))
end

@generated function _props_nt(k::_PropsNTKernel{names}, args::Tuple) where names
    refs = Any[names...]
    argexprs = Any[:(args[$i]) for i in eachindex(refs)]
    return _props_nt_expr(refs, argexprs)
end



struct _PropSelector{src_names, trg_names} <: Function end

@generated function (::_PropSelector{src_names,trg_names})(x) where {src_names,trg_names}
    vals = Any[_getprop_expr(:x, ref) for ref in src_names]
    return :(NamedTuple{$(QuoteNode(trg_names))}(($(vals...),)))
end

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
const PropSelFunction{src_names, trg_names} = PropertyFunctions.PropertyFunction{src_names, PropertyFunctions._PropSelector{src_names, trg_names}}
export PropSelFunction

PropSelFunction{src_names,trg_names}() where {src_names,trg_names} = PropertyFunction{src_names}(_PropSelector{src_names,trg_names}())
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

(or equivalently `@pf (c = \$c, d = \$a)`)
can be used to select (and rename) properties, and they have special
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
        props, argsym, arg_expr = subst_prop_refs(expr)

        names_expr = :(())
        append!(names_expr.args, map(QuoteNode, props))

        res_expr = quote
            local sel_prop_func
            @inline sel_prop_func($(esc(argsym))) = $(esc(arg_expr))

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
    elseif expr.head === :call || expr.head === :kw || expr.head === :(=) || expr.head === :(::) ||
            (expr.head === :. && length(expr.args) == 2 && _is_dotcall_argtuple(expr.args[2]))
        # Callees (incl. broadcast callees), keyword-argument names, assignment
        # targets and type annotations are not value positions:
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
    if expr.head == :kw || expr.head == :(=)
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
    expr.head == :tuple || return nothing
    args = expr.args
    entries = if length(args) == 1 && args[1] isa Expr && (args[1]::Expr).head == :parameters
        (args[1]::Expr).args
    elseif !isempty(args) && all(e -> e isa Expr && e.head == :(=), args)
        args
    else
        return nothing
    end
    inputs = _PropRef[]
    output = Symbol[]
    for arg in entries
        src_trg = _unpack_ntelem_assignment(arg)
        if isnothing(src_trg)
            return nothing
        else
            push!(output, src_trg[1])
            push!(inputs, src_trg[2])
        end
    end
    return inputs => output
end



# ToDo - necessary?
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(tbl) =
#    broadcast(_PropsNTKernel(bpf.f), _prop_cols(bpf.f, Tables.columns(tbl))...)

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
    Broadcast.broadcasted(bstyle, _PropsNTKernel(pf), cols...)
end

@inline function _broadcasted_impl(::Val{true}, pf::PropSelFunction{src_names,trg_names}, xs::AbstractArray) where {src_names,trg_names}
    cols = _prop_cols(pf, Tables.columns(xs))
    named_cols = NamedTuple{trg_names}(cols)
    ctor = Tables.materializer(xs)
    return ctor(named_cols)
end

@inline function _broadcasted_impl(::Val{false}, pf::PropertyFunction, xs::AbstractArray)
    # ToDo: Use StructArray broadcast style here as well.
    Broadcast.broadcasted(pf.sel_prop_func, xs)
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
#    broadcast(_PropsNTKernel(bpf.f), map(StridedView, _prop_cols(bpf.f, Tables.columns(tbl)))...)

#@inline (bpf::BroadcastFunction{<:PropertyFunction})(::Type{LazyArray}, tbl) =
#    LazyArray(Broadcast.broadcasted(bpf.f, tbl))
