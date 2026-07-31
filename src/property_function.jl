# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


"""
    abstract type PropertyFunctions._PropSelector <: Function

Abstract supertype of pure property selectors and extractors.
"""
abstract type _PropSelector <: Function end


_getprop_expr(base, path::Tuple) = foldl((e, name) -> Expr(:., e, QuoteNode(name)), path, init = base)


"""
    PPath{path}

Represents a path of nested property names.

Constructors:

```julia
PPath(:a, :b)
PPath{(:a, :b)}()
```

`PPath` objects are callable, `PPath(:a, :b)(x)` returns `x.a.b`.

The property paths that a [`PropertyFunction`](@ref) may access are part of
its type signature, `PropertyFunction{Tuple{PPath{(:a, :b)}, ...}}`.

Public but not exported.
"""
struct PPath{path} <: _PropSelector
    function PPath{path}() where path
        path isa Tuple{Vararg{Symbol}} && !isempty(path) ||
            throw(ArgumentError("The path of a PPath must be a non-empty tuple of Symbols"))
        return new{path}()
    end
end

PPath(path::Symbol...) = PPath{path}()

@generated (::PPath{path})(x) where path = _getprop_expr(:x, path)

_path(::Type{PPath{path}}) where path = path
_path(::PPath{path}) where path = path

"""
    const PPaths = Tuple{Vararg{PPath}}

The supertype of the property-path `Tuple` types used in the first type
parameter of [`PropertyFunction`](@ref).

Public but not exported.
"""
const PPaths = Tuple{Vararg{PPath}}

_paths_type(paths) = Tuple{(PPath{p} for p in paths)...}
_paths(::Type{Paths}) where {Paths<:PPaths} = (Paths.parameters...,)


_is_prefix_of(a::Tuple, b::Tuple) = length(a) < length(b) && a === b[1:length(a)]
_overlaps(a::Tuple, b::Tuple) = a === b || _is_prefix_of(a, b) || _is_prefix_of(b, a)

# Drop paths that are covered by a path to a parent property:
_merge_paths(paths) = filter(p -> !any(q -> _is_prefix_of(q, p), paths), paths)

function _pairwise_disjoint(paths)
    for i in eachindex(paths), j in firstindex(paths):(i - 1)
        _overlaps(paths[i], paths[j]) && return false
    end
    return true
end


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
generated argument name and return the referenced property paths, the
argument name and the modified expression.

Usage:

```julia
paths, argsym, new_expr = subst_prop_refs(expr)
```
"""
function subst_prop_refs(expr)
    paths = Tuple{Vararg{Symbol}}[]  # referenced property paths, in order of first use
    argsym = gensym(:x)
    new_expr = subst_prop_refs_helper(deepcopy(expr), false, paths, argsym) # Start out _not_ in a quote context (false)
    return _merge_paths(paths), argsym, new_expr
end

# Modeled after Base.Base._lift_one_interp!:
subst_prop_refs_helper(v, _, _, _) = v

function subst_prop_refs_helper(expr::Expr, in_quote_context, paths, argsym)
    if !in_quote_context
        path = _dollar_path(expr)
        if !isnothing(path)
            path in paths || push!(paths, path)
            return _getprop_expr(argsym, path)
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
        new_e = subst_prop_refs_helper(e, in_quote_context, paths, argsym)
        if in_params && !isnothing(path)
            # Preserve the property name of `$prop` in named-tuple/kwarg shorthand position:
            new_e = Expr(:kw, last(path), new_e)
        end
        expr.args[i] = new_e
    end
    expr
end


# Validates the paths in a Paths type parameter, resolved at compile time
# so that valid constructions carry no runtime cost:
@generated function _check_paths(::Type{Paths}) where {Paths<:PPaths}
    paths = Any[_path(P) for P in Paths.parameters]
    for p in paths
        p isa Tuple{Vararg{Symbol}} && !isempty(p) ||
            return :(throw(ArgumentError("Property paths must be non-empty tuples of Symbols")))
    end
    _pairwise_disjoint(paths) ||
        return :(throw(ArgumentError("The property paths of a PropertyFunction must be pairwise disjoint")))
    return :(nothing)
end

"""
    struct PropertyFunction{Paths<:Tuple, F<:Function} <: Function

Use only for dispatch in special cases. User code should *not* create
instances of `PropertyFunction` directly - use the [`@pf`](@ref) or
[`@fp`](@ref) macros instead.

The `Paths` type parameter is a `Tuple` type of [`PPath`](@ref) types
(`Paths <: PPaths`), e.g. `Tuple{PPath{(:a,)}, PPath{(:b, :c)}}`. It is the
minimal cover of the property paths the function may access (a path
subsumes all paths below it) and is part of the public API, so that
specialized implementations (e.g. for tables with expensive column access)
can rely on it. The paths in `Paths` must be pairwise disjoint (enforced
during construction), and their order, while part of the type identity,
carries no semantic meaning. The type parameter `F` is internal and
subject to change.
"""
struct PropertyFunction{Paths<:PPaths, F<:Function} <: Function
    sel_prop_func::F

    function PropertyFunction{Paths,F}(sel_prop_func) where {Paths<:PPaths,F<:Function}
        _check_paths(Paths)
        return new{Paths,F}(sel_prop_func)
    end
end
export PropertyFunction

PropertyFunction{Paths}(sel_prop_func::F) where {Paths<:PPaths,F<:Function} = PropertyFunction{Paths,F}(sel_prop_func)

(pf::PropertyFunction)(x) = pf.sel_prop_func(x)


struct _PropGetter{name} <: Function end
@inline (::_PropGetter{name})(x) where name = getproperty(x, name)


"""
    PropertyFunctions.subcolumn(col::AbstractArray, name::Symbol)
    PropertyFunctions.subcolumn(col::AbstractArray, ::Val{name})

Get the column `name` of an array `col` of structs.

Returns `getproperty.(col, name)` by default, `StructArray` columns
provide zero-copy access. Specialize for array types that support
efficient column access.

The `Val` variants keep the property name in the type domain, which is
required for type inference on columns that are not `StructArray`s.
"""
@inline subcolumn(col::AbstractArray, name::Symbol) = getproperty.(col, name)
@inline subcolumn(col::StructArray, name::Symbol) = getproperty(col, name)
@inline subcolumn(col::AbstractArray, ::Val{name}) where name = broadcast(_PropGetter{name}(), col)
@inline subcolumn(col::StructArray, ::Val{name}) where name = getproperty(col, name)

function _getcol_expr(base, path::Tuple)
    ref = Expr(:., base, QuoteNode(first(path)))
    for name in Base.tail(path)
        ref = :(subcolumn($ref, Val($(QuoteNode(name)))))
    end
    return ref
end

@generated function _prop_cols(pf::PropertyFunction{Paths}, cols) where Paths
    expr = :(())
    for P in Paths.parameters
        push!(expr.args, _getcol_expr(:cols, _path(P)))
    end
    return expr
end


# Broadcast kernel that assembles the referenced properties into a (possibly
# nested) NamedTuple and passes it to the wrapped function as a single argument:
struct _PropsNTKernel{Paths<:PPaths,F<:Function} <: Function
    sel_prop_func::F
end

_PropsNTKernel(pf::PropertyFunction{Paths,F}) where {Paths,F} = _PropsNTKernel{Paths,F}(pf.sel_prop_func)

@inline (k::_PropsNTKernel)(args...) = k.sel_prop_func(_props_nt(k, args))

function _props_nt_expr(paths::Vector, argexprs::Vector)
    ks = Symbol[]
    vs = Any[]
    for path in paths
        head = first(path)::Symbol
        head in ks && continue
        push!(ks, head)
        idxs = findall(p -> first(p) === head, paths)
        if length(idxs) == 1 && length(paths[only(idxs)]) == 1
            push!(vs, argexprs[only(idxs)])
        else
            subpaths = Any[Base.tail(paths[i]::Tuple{Vararg{Symbol}}) for i in idxs]
            push!(vs, _props_nt_expr(subpaths, argexprs[idxs]))
        end
    end
    return :(NamedTuple{$(QuoteNode((ks...,)))}(($(vs...),)))
end

@generated function _props_nt(k::_PropsNTKernel{Paths}, args::Tuple) where Paths
    paths = Any[_path(P) for P in Paths.parameters]
    argexprs = Any[:(args[$i]) for i in eachindex(paths)]
    return _props_nt_expr(paths, argexprs)
end

# The properties of x that pf may access, as a (possibly nested) NamedTuple.
# Semantically, pf(x) == pf.sel_prop_func(_restricted_props(pf, x)):
@generated function _restricted_props(pf::PropertyFunction{Paths}, x) where Paths
    paths = Any[_path(P) for P in Paths.parameters]
    argexprs = Any[_getprop_expr(:x, p) for p in paths]
    return _props_nt_expr(paths, argexprs)
end

# Zero-copy nested StructArray of the referenced property columns, structured
# like the NamedTuple that _PropsNTKernel passes to the wrapped function:
function _props_sa_expr(paths::Vector, argexprs::Vector)
    ks = Symbol[]
    vs = Any[]
    for path in paths
        head = first(path)::Symbol
        head in ks && continue
        push!(ks, head)
        idxs = findall(p -> first(p) === head, paths)
        if length(idxs) == 1 && length(paths[only(idxs)]) == 1
            push!(vs, argexprs[only(idxs)])
        else
            subpaths = Any[Base.tail(paths[i]::Tuple{Vararg{Symbol}}) for i in idxs]
            push!(vs, _props_sa_expr(subpaths, argexprs[idxs]))
        end
    end
    return :(StructArray(NamedTuple{$(QuoteNode((ks...,)))}(($(vs...),))))
end

@generated function _props_structarray(k::_PropsNTKernel{Paths}, cols::Tuple) where Paths
    paths = Any[_path(P) for P in Paths.parameters]
    argexprs = Any[:(cols[$i]) for i in eachindex(paths)]
    return _props_sa_expr(paths, argexprs)
end


# Selects properties as a Tuple:
struct _TplPropSelector{Paths<:PPaths} <: _PropSelector end

@generated function (::_TplPropSelector{Paths})(x) where Paths
    return Expr(:tuple, (_getprop_expr(:x, _path(P)) for P in Paths.parameters)...)
end

# Selects properties as a NamedTuple:
struct _NTPropSelector{trg_names, Paths<:PPaths} <: _PropSelector end

@generated function (::_NTPropSelector{trg_names, Paths})(x) where {trg_names, Paths}
    vals = Any[_getprop_expr(:x, _path(P)) for P in Paths.parameters]
    return :(NamedTuple{$(QuoteNode(trg_names))}(($(vals...),)))
end

"""
    PropSelFunction{Paths<:Tuple,trg_names} <: PropertyFunction

A special kind of `PropertyFunction` that selects (and possibly renames)
properties, but does no other computations.

A PropSelFunction can be constructed via the [`@pf`](@ref) macro

```julia
propsel = @pf (;\$c, d = \$a)
```

or directly via

```julia
propsel = PropSelFunction(:c, :a => :d)
propsel = PropSelFunction(:c, PPath(:a, :b) => :d)
```

or

```julia
propsel = PropSelFunction{Tuple{PPath{(:c,)}, PPath{(:a,)}}, (:c, :d)}()
```

or just

```julia
PropSelFunction{Tuple{PPath{(:c,)}, PPath{(:a,)}}}()
```

if no property name mapping is required.

The selected property paths of a `PropSelFunction` are always pairwise
disjoint: [`@pf`](@ref) generates plain `PropertyFunction`s for
selections with duplicated or overlapping sources, while the
`PropSelFunction` constructors reject such selections.

See also [`@pf`](@ref).
"""
const PropSelFunction{Paths, trg_names} = PropertyFunctions.PropertyFunction{Paths, PropertyFunctions._NTPropSelector{trg_names, Paths}}
export PropSelFunction

function PropSelFunction{Paths,trg_names}() where {Paths<:PPaths,trg_names}
    trg_names isa Tuple{Vararg{Symbol}} && length(trg_names) == length(Paths.parameters) ||
        throw(ArgumentError("The target names of a PropSelFunction must be a tuple of Symbols matching the number of source paths"))
    allunique(trg_names) ||
        throw(ArgumentError("The target names of a PropSelFunction must be unique"))
    return PropertyFunction{Paths}(_NTPropSelector{trg_names,Paths}())
end

function PropSelFunction{Paths}() where {Paths<:PPaths}
    _check_paths(Paths)
    return PropSelFunction{Paths, _trg_names(Paths)}()
end

_trg_names(::Type{Paths}) where {Paths<:PPaths} = map(P -> last(_path(P)), _paths(Paths))

function PropSelFunction(selects::Union{Symbol, PPath, Pair{<:Union{Symbol, PPath}, Symbol}}...)
    paths = map(_sel_path, selects)
    trg_names = map(_sel_trg, selects)
    PropSelFunction{_paths_type(paths), trg_names}()
end

_sel_path(s::Symbol) = (s,)
_sel_path(p::PPath) = _path(p)
_sel_path(src_trg::Pair) = _sel_path(src_trg[1])
_sel_trg(s::Symbol) = s
_sel_trg(p::PPath) = last(_path(p))
_sel_trg(src_trg::Pair) = src_trg[2]



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

Expressions that purely select properties, like

```julia
propsel = @pf (;\$c, d = \$a)
```

(or equivalently `@pf (c = \$c, d = \$a)`), as well as tuple selections
`@pf (\$c, \$a)` and single-property extractions `@pf \$a`, have special
broadcasting optimizations for table-like arguments. This can make
broadcasts of such property selections zero-copy O(1) operations:

```julia
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
    selection = _get_property_selection(expr)
    path = _dollar_path(expr)
    if !isnothing(selection)
        kind, paths, trg_names = selection
        PathsT = _paths_type(paths)
        if kind === :namedtuple
            return :(PropSelFunction{$PathsT, $(QuoteNode((trg_names...,)))}())
        else
            return :(PropertyFunction{$PathsT}($(_TplPropSelector{PathsT})()))
        end
    elseif !isnothing(path)
        return :(PropertyFunction{$(Tuple{PPath{path}})}($(PPath{path})()))
    else
        paths, argsym, arg_expr = subst_prop_refs(expr)

        res_expr = quote
            local sel_prop_func
            @inline sel_prop_func($(esc(argsym))) = $(esc(arg_expr))

            PropertyFunction{$(_paths_type(paths))}(sel_prop_func)
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


_unpack_ntelem_assignment(::Any) = nothing
function _unpack_ntelem_assignment(expr::Expr)
    if expr.head == :kw || expr.head == :(=)
        path = _dollar_path(expr.args[2])
        if !isnothing(path) && expr.args[1] isa Symbol
            return expr.args[1]::Symbol => path
        else
            return nothing
        end
    else
        path = _dollar_path(expr)
        if !isnothing(path)
            return last(path) => path
        else
            return nothing
        end
    end
end

_get_property_selection(::Any) = nothing
function _get_property_selection(expr::Expr)
    expr.head == :tuple || return nothing
    args = expr.args
    paths = Tuple{Vararg{Symbol}}[]
    trg_names = Symbol[]
    entries = if length(args) == 1 && args[1] isa Expr && (args[1]::Expr).head == :parameters
        (args[1]::Expr).args
    elseif !isempty(args) && all(e -> e isa Expr && e.head == :(=), args)
        args
    elseif !isempty(args) && all(e -> !isnothing(_dollar_path(e)), args)
        for e in args
            push!(paths, _dollar_path(e))
        end
        return _pairwise_disjoint(paths) ? (:tuple, paths, trg_names) : nothing
    else
        return nothing
    end
    for arg in entries
        trg_path = _unpack_ntelem_assignment(arg)
        if isnothing(trg_path)
            return nothing
        else
            push!(trg_names, trg_path[1])
            push!(paths, trg_path[2])
        end
    end
    return _pairwise_disjoint(paths) ? (:namedtuple, paths, trg_names) : nothing
end



Base.:∘(p2::PPath, p1::PPath) = PPath{(_path(p1)..., _path(p2)...)}()

"""
    fg = f ∘ pf::PropertyFunction

Function composition with a property function as the inner function
results in a `PropertyFunction` again, since `fg` accesses the same
properties as `pf`.

Compositions of pure property selections and extractions fuse into single
selections that may access fewer and more specific properties, e.g.
`@pf(\$x) ∘ @pf((; x = \$a.b, y = \$c)) === @pf \$a.b`.
"""
Base.:∘(f, pf::PropertyFunction{Paths}) where {Paths<:PPaths} =
    PropertyFunction{Paths}(f ∘ pf.sel_prop_func)

@generated function Base.:∘(
    pf2::PropertyFunction{Paths2,F2}, pf1::PropertyFunction{Paths1,F1}
) where {Paths2<:PPaths,F2<:_PropSelector,Paths1<:PPaths,F1<:_PropSelector}
    fused = _fused_selection_expr(F2, F1)
    isnothing(fused) && return :(PropertyFunction{$Paths1}(pf2.sel_prop_func ∘ pf1.sel_prop_func))
    return fused
end

# Resolves a path into the output of a selector to a path into its input,
# returns nothing where impossible:
_resolve_path(::Type{PPath{q}}, path::Tuple) where q = (q..., path...)
_resolve_path(::Type{<:_TplPropSelector}, ::Tuple) = nothing
function _resolve_path(::Type{_NTPropSelector{trg_names,Paths}}, path::Tuple) where {trg_names,Paths}
    isempty(path) && return nothing
    i = findfirst(==(first(path)), trg_names)
    isnothing(i) && return nothing
    return (_path(Paths.parameters[i])..., Base.tail(path)...)
end

_selector_paths(::Type{PPath{path}}) where path = Any[path]
_selector_paths(::Type{_TplPropSelector{Paths}}) where {Paths} = Any[_path(P) for P in Paths.parameters]
_selector_paths(::Type{_NTPropSelector{trg_names,Paths}}) where {trg_names,Paths} = Any[_path(P) for P in Paths.parameters]

function _fused_selection_expr(::Type{F2}, ::Type{F1}) where {F2<:_PropSelector,F1<:_PropSelector}
    resolved = [_resolve_path(F1, path) for path in _selector_paths(F2)]
    any(isnothing, resolved) && return nothing
    # Disjoint selector sources stay disjoint under path resolution:
    @assert _pairwise_disjoint(resolved)
    PathsT = _paths_type(resolved)
    if F2 <: PPath
        return :(PropertyFunction{$PathsT}($(PPath{only(resolved)})()))
    elseif F2 <: _NTPropSelector
        return :(PropSelFunction{$PathsT, $(QuoteNode(F2.parameters[1]))}())
    else
        return :(PropertyFunction{$PathsT}($(_TplPropSelector{PathsT})()))
    end
end


# ToDo - necessary?
#@inline (bpf::BroadcastFunction{<:PropertyFunction})(tbl) =
#    broadcast(_PropsNTKernel(bpf.f), _prop_cols(bpf.f, Tables.columns(tbl))...)

_colaccess(xs) = Val(Tables.columnaccess(xs))

@inline function Broadcast.broadcasted(pf::PropertyFunction, xs::AbstractArray)
    _broadcasted_impl(_colaccess(xs), pf, xs)
end

# A property function that references no properties has no columns to broadcast over:
@inline Broadcast.broadcasted(pf::PropertyFunction{Tuple{}}, xs::AbstractArray) =
    _broadcasted_impl(Val(false), pf, xs)

@inline function _broadcasted_impl(::Val{true}, pf::PropertyFunction, xs::AbstractArray)
    cols = _prop_cols(pf, Tables.columns(xs))
    bstyle = BroadcastStyle(typeof(StructArray(cols)))
    Broadcast.broadcasted(bstyle, _PropsNTKernel(pf), cols...)
end

# Pure property selections broadcast as zero-copy column selections:

@inline _broadcasted_impl(::Val{true}, pf::PropertyFunction{Paths, <:PPath}, xs::AbstractArray) where {Paths<:PPaths} =
    only(_prop_cols(pf, Tables.columns(xs)))

@inline _broadcasted_impl(::Val{true}, pf::PropertyFunction{Paths, <:_TplPropSelector}, xs::AbstractArray) where {Paths<:PPaths} =
    StructArray(_prop_cols(pf, Tables.columns(xs)))

@inline function _broadcasted_impl(::Val{true}, pf::PropSelFunction{Paths,trg_names}, xs::AbstractArray) where {Paths<:PPaths,trg_names}
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
