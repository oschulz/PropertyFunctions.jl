# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


RuntimeGeneratedFunctions.init(@__MODULE__)


# Fixed input argument name, so that equal expressions yield equal generated
# function types across constructions and processes:
const _runtime_pf_argsym = Symbol("#pf_arg#")


# Symbols occurring in an expression, as a syntactic overapproximation of the
# names it may reference. Dotted operators like `.+` reference their undotted
# form after lowering, and update operators like `+=` carry their base
# operator in the expression head:
_referenced_syms!(syms::Set{Symbol}, @nospecialize(x)) = syms

function _referenced_syms!(syms::Set{Symbol}, sym::Symbol)
    push!(syms, sym)
    sym_str = string(sym)
    if length(sym_str) > 1 && sym_str[begin] == '.'
        push!(syms, Symbol(sym_str[begin+1:end]))
    end
    return syms
end

function _referenced_syms!(syms::Set{Symbol}, expr::Expr)
    head_str = string(expr.head)
    if length(head_str) > 1 && head_str[end] == '='
        _referenced_syms!(syms, Symbol(head_str[begin:end-1]))
    end
    foreach(e -> _referenced_syms!(syms, e), expr.args)
    return syms
end

function _used_env_names(@nospecialize(env), @nospecialize(body))
    refs = _referenced_syms!(Set{Symbol}(), body)
    return sort!(filter!(in(refs), collect(Symbol, keys(env))))
end


_rgf_argnames(::RuntimeGeneratedFunction{argnames}) where argnames = argnames

_rgf_cache_tag(::RuntimeGeneratedFunction{argnames, cache_tag}) where {argnames, cache_tag} = cache_tag

function _rgf_id(
    ::RuntimeGeneratedFunction{argnames, cache_tag, context_tag, id}
) where {argnames, cache_tag, context_tag, id}
    return id
end

# The generated code of a RuntimeGeneratedFunction is looked up in a cache
# that downstream precompile images do not preserve and that holds bodies
# only via weak references. So a runtime property function stored in a
# precompiled downstream constant fails its first call with a KeyError on
# the function id, resp. with an assertion failure if the cache entry exists
# but its body has been garbage collected. The body expression carried in
# the instance survives, though, so re-registering it makes all instances of
# the function callable again:
function _lost_rgf_body(err, rgf::RuntimeGeneratedFunction)
    err isa KeyError && return err.key === _rgf_id(rgf)
    err isa AssertionError && return isnothing(_current_rgf_body(rgf))
    return false
end

function _current_rgf_body(rgf::RuntimeGeneratedFunction)
    try
        RuntimeGeneratedFunctions._lookup_body(_rgf_cache_tag(rgf), _rgf_id(rgf))
    catch err
        err isa KeyError || rethrow()
        nothing
    end
end

@noinline function _restore_rgf_body(rgf::RuntimeGeneratedFunction)
    body = rgf.body
    body isa Expr || error("Cannot restore runtime property function, its body expression is no longer available")
    # body already went through the constructor's closure transformation, so
    # transforming it again would register it under a different id. Passing
    # it unchanged also re-caches the very expression object held by rgf,
    # keeping the weakly referenced cache entry alive as long as rgf itself:
    RuntimeGeneratedFunction(
        @__MODULE__, @__MODULE__,
        Expr(:->, Expr(:tuple, _rgf_argnames(rgf)...), body);
        opaque_closures = false
    )
    return nothing
end


# Wraps the compiled function of a runtime-constructed PropertyFunction
# together with the values of the env entries it references, which are
# passed as leading arguments:
struct _RuntimePFBody{F<:RuntimeGeneratedFunction, V<:Tuple} <: Function
    rgf::F
    envvals::V
end

@inline function (f::_RuntimePFBody)(x)
    try
        f.rgf(f.envvals..., x)
    catch err
        _lost_rgf_body(err, f.rgf) || rethrow()
        _restore_rgf_body(f.rgf)
        f.rgf(f.envvals..., x)
    end
end

function Base.:(==)(a::_RuntimePFBody, b::_RuntimePFBody)
    return typeof(a.rgf) === typeof(b.rgf) && isequal(a.envvals, b.envvals)
end

function Base.hash(f::_RuntimePFBody, h::UInt)
    return hash(f.envvals, hash(_rgf_id(f.rgf), hash(:_RuntimePFBody, h)))
end


"""
    PropertyFunction(expr::Union{Expr,Symbol,Number}, env = (;))

Compile the expression `expr`, which references input properties via
`\$property` like [`@pf`](@ref), to a `PropertyFunction` at runtime.

`PropertyFunction(:(\$a + \$c^2))` behaves like `@pf \$a + \$c^2`.
Use it where property functions must be constructed from expressions that
only become available at runtime, e.g. from configuration files.

# Extended help

In contrast to `@pf`, expressions must not contain macro calls (evaluate
macro-generated values beforehand and pass them via `env`) and input calls
`f(_)` are not supported.

Free names in `expr` are resolved via `env`, a `NamedTuple` or an
`AbstractDict{Symbol}`. Names not found in `env` resolve in the
`PropertyFunctions` module scope, so `Base` functions are available without
an `env` entry. `env` entries that `expr` does not reference are ignored.
Note that a bare `Symbol` is a free name, not a property reference:
properties are always referenced via `\$property`.

Example:

```julia
pf = PropertyFunction(:(f(\$a) + b), (f = sin, b = 42))
pf((a = 0.0,)) == 42.0
```

The name `#pf_arg#` is reserved and must not occur in `expr` or as an `env` key.
"""
function PropertyFunction(@nospecialize(expr::Union{Expr,Symbol,Number}), @nospecialize(env = (;)))
    sel_pf = _selection_pf(expr)
    isnothing(sel_pf) || return sel_pf

    _runtime_pf_argsym in _referenced_syms!(Set{Symbol}(), expr) && throw(ArgumentError("Expressions compiled to a PropertyFunction must not contain the reserved name $_runtime_pf_argsym"))
    _runtime_pf_argsym in keys(env) && throw(ArgumentError("env passed to the PropertyFunction constructor must not contain the reserved name $_runtime_pf_argsym"))

    paths, argsym, callees, has_macro, body = subst_prop_refs(expr, _runtime_pf_argsym)
    has_macro && throw(ArgumentError("Expressions compiled to a PropertyFunction must not contain macro calls, pass macro-generated values via env instead"))
    isempty(callees) || throw(ArgumentError("Expressions compiled to a PropertyFunction don't support input calls f(_)"))

    envnames = _used_env_names(env, body)
    envvals = ([env[name] for name in envnames]...,)
    fexpr = Expr(:->, Expr(:tuple, envnames..., argsym), body)
    rgf = RuntimeGeneratedFunction(@__MODULE__, @__MODULE__, fexpr)
    return PropertyFunction{_paths_type(paths)}(_RuntimePFBody(rgf, envvals))
end
