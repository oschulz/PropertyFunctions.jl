# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

module PropertyFunctionsAccessorsExt

using Accessors: Accessors, PropertyLens
using PropertyFunctions: PropertyFunctions, PropertyFunction, PropSelFunction, PPath, PPaths
using PropertyFunctions: _NTPropSelector, _TplPropSelector, _PropSelector, _path, _paths, _paths_type

_flatten_optic(o::ComposedFunction) = (_flatten_optic(o.inner)..., _flatten_optic(o.outer)...)
_flatten_optic(o) = (o,)

_lens_name(::PropertyLens{name}) where name = name

_leading_path(parts::Tuple{}) = ()
_leading_path(parts::Tuple) = first(parts) isa PropertyLens ?
    (_lens_name(first(parts)), _leading_path(Base.tail(parts))...) : ()

# Full property path of optics that access properties only, nothing otherwise:
_pure_path(optic::PropertyLens) = (_lens_name(optic),)
function _pure_path(optic::ComposedFunction)
    parts = _flatten_optic(optic)
    path = _leading_path(parts)
    length(path) == length(parts) ? path : nothing
end

# Optics that begin with a property access. Since `∘` is left-associative,
# this covers all `@o`-generated and naturally composed optics of that kind:
const _PropOptic = Union{PropertyLens,ComposedFunction{<:Any,<:PropertyLens}}

"""
    PPath(optic::Union{Accessors.PropertyLens,ComposedFunction{<:Any,<:Accessors.PropertyLens}})
    convert(PPath, optic)

Convert a pure property-access optic like `@o _.a.b` into a property path.
"""
function PropertyFunctions.PPath(optic::_PropOptic)
    path = _pure_path(optic)
    isnothing(path) && throw(ArgumentError("Optic accesses more than properties and can't be converted to a PPath"))
    PPath{path}()
end

Base.convert(::Type{PPath}, optic::_PropOptic) = PPath(optic)

"""
    PropertyFunction(optic::Union{Accessors.PropertyLens,ComposedFunction{<:Any,<:Accessors.PropertyLens}})
    convert(PropertyFunction, optic)

Convert an optic like `@o _.a.b` or `@o log(_.a.b)` into a property
function, based on the properties the optic accesses. The resulting
function behaves like the optic itself.
"""
PropertyFunctions.PropertyFunction(optic::PropertyLens) = _pf_from_path((_lens_name(optic),))

function PropertyFunctions.PropertyFunction(optic::ComposedFunction{<:Any, <:PropertyLens})
    pure = _pure_path(optic)
    isnothing(pure) || return _pf_from_path(pure)
    path = _leading_path(_flatten_optic(optic))
    PropertyFunction{Tuple{PPath{path}}}(optic)
end

_pf_from_path(path::Tuple) = PropertyFunction{Tuple{PPath{path}}}(PPath{path}())

Base.convert(::Type{PropertyFunction}, optic::_PropOptic) = PropertyFunction(optic)

"""
    PropSelFunction(optic::Union{Accessors.PropertyLens,ComposedFunction{<:Any,<:Accessors.PropertyLens}})
    convert(PropSelFunction, optic)

Convert a pure property-access optic like `@o _.a.b` into a property
selection function. Unlike the optic and `PropertyFunction(optic)`, the
result returns a `NamedTuple` named after the last property in the
access path: `PropSelFunction(@o _.a.b)(x)` is `(b = x.a.b,)`.
"""
function PropertyFunctions.PropSelFunction(optic::_PropOptic)
    path = _pure_path(optic)
    isnothing(path) && throw(ArgumentError("Optic accesses more than properties and can't be converted to a PropSelFunction"))
    PropSelFunction{Tuple{PPath{path}}, (last(path),)}()
end

Base.convert(::Type{PropSelFunction}, optic::_PropOptic) = PropSelFunction(optic)


_path_optic(path::Tuple) = foldl((o, name) -> PropertyLens{name}() ∘ o, Base.tail(path), init = PropertyLens{first(path)}())

"""
    Accessors.set(obj, pf::PropertyFunction, vals)

Set the properties accessed by `pf` in `obj`.

Semantically, `pf` is the function wrapped by it composed with a
restriction of its argument to the accessed property paths. So `set`
restricts `obj` to those paths, sets the result of the wrapped function
on the restriction via `Accessors.set`, and writes the updated
restriction back to `obj`.

Supported for property functions whose wrapped function `Accessors.set`
can invert: pure property extractions and selections like `@pf \$a.b`
(a single value), `@pf (\$a, \$b.c)` (a `Tuple` of values) and
`@pf (;\$a, c = \$b)` (a `NamedTuple` of values), as well as invertible
functions and optics composed with them, like `exp ∘ @pf \$a.b`.
"""
function Accessors.set(obj, pf::PropertyFunction, vals)
    props = PropertyFunctions._restricted_props(pf, obj)
    new_props = Accessors.set(props, pf.sel_prop_func, vals)
    return _set_restricted_props(obj, pf, new_props)
end

@generated function _set_restricted_props(obj, pf::PropertyFunction{Paths}, new_props) where {Paths}
    ex = :obj
    for P in Paths.parameters
        p = _path(P)
        ex = :(Accessors.set($ex, _path_optic($(QuoteNode(p))), $(PropertyFunctions._getprop_expr(:new_props, p))))
    end
    return ex
end

Accessors.set(obj, p::PPath, val) = Accessors.set(obj, _path_optic(_path(p)), val)

@generated function Accessors.set(obj, ::_TplPropSelector{Paths}, vals::Tuple) where {Paths}
    ex = :obj
    for (i, P) in enumerate(Paths.parameters)
        ex = :(Accessors.set($ex, _path_optic($(QuoteNode(_path(P)))), vals[$i]))
    end
    return ex
end

@generated function Accessors.set(obj, ::_NTPropSelector{trg_names, Paths}, vals::NamedTuple) where {trg_names, Paths}
    ex = :obj
    for (trg, P) in zip(trg_names, Paths.parameters)
        ex = :(Accessors.set($ex, _path_optic($(QuoteNode(_path(P)))), vals.$trg))
    end
    return ex
end

end # module
