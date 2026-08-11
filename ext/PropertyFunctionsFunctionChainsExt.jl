# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

module PropertyFunctionsFunctionChainsExt

using FunctionChains: FunctionChains, FunctionChain, FFanout, ffchain
using PropertyFunctions: PropertyFunctions, PropertyFunction, PropSelFunction, PPath, PPaths
using PropertyFunctions: input_property_paths, _combined_paths_type
using PropertyFunctions: _path, _paths, _paths_type, _pairwise_disjoint, _TplPropSelector

# A property function followed by another function accesses the same
# properties, so function chains fuse into the property function, with
# ffchain keeping the wrapped function chain flat. Adjacent property
# functions fuse via composition, which fuses pure property selections:

_pushed_into(pf::PropertyFunction{Paths}, f) where {Paths<:PPaths} =
    PropertyFunction{Paths}(ffchain(pf.sel_prop_func, f))

FunctionChains.fuse_functions(pf::PropertyFunction, f) = (_pushed_into(pf, f),)
FunctionChains.fuse_functions(pf::PropertyFunction, f::PropertyFunction) = (f ∘ pf,)

# Disambiguation between composition specializations of both packages:
Base.:∘(fc::FunctionChain, pf::PropertyFunction) = _pushed_into(pf, fc)

FunctionChains.with_intermediate_results(pf::PropertyFunction, x) =
    FunctionChains.with_intermediate_results(pf.sel_prop_func, x)


# A fanout applies all component functions to the same input, so a fanout of
# property functions accesses the union of their property paths and becomes
# a property function containing a fanout, keeping the column-pruning
# broadcast optimizations. ffanout explicitly supports such specializations:

_generic_pf_fanout(fs::Tuple) =
    PropertyFunction{_combined_paths_type(map(input_property_paths, fs)...)}(FFanout(fs))

_generic_pf_fanout(fs::NamedTuple) =
    PropertyFunction{_combined_paths_type(map(input_property_paths, values(fs))...)}(FFanout(fs))

_pf_fanout(fs::Tuple) = _generic_pf_fanout(fs)
_pf_fanout(fs::NamedTuple) = _generic_pf_fanout(fs)

# Fanouts of pure property extractions with pairwise-disjoint paths fuse
# into pure property selections, which broadcast zero-copy:

@generated function _pf_fanout(fs::Tuple{Vararg{PropertyFunction{<:PPaths, <:PPath}}})
    paths = Any[_path(P.parameters[2]) for P in fs.parameters]
    _pairwise_disjoint(paths) || return :(_generic_pf_fanout(fs))
    PathsT = _paths_type(paths)
    return :(PropertyFunction{$PathsT}($(_TplPropSelector{PathsT})()))
end

@generated function _pf_fanout(fs::NamedTuple{names, <:Tuple{Vararg{PropertyFunction{<:PPaths, <:PPath}}}}) where names
    paths = Any[_path(P.parameters[2]) for P in fs.parameters[2].parameters]
    _pairwise_disjoint(paths) || return :(_generic_pf_fanout(fs))
    PathsT = _paths_type(paths)
    return :(PropSelFunction{$PathsT, $(QuoteNode(names))}())
end

FunctionChains.ffanout(f1::PropertyFunction, fs::Vararg{PropertyFunction}) = _pf_fanout((f1, fs...))
FunctionChains.ffanout(fs::Tuple{PropertyFunction, Vararg{PropertyFunction}}) = _pf_fanout(fs)
FunctionChains.ffanout(fs::NamedTuple{names, <:Tuple{PropertyFunction, Vararg{PropertyFunction}}}) where names = _pf_fanout(fs)

# Property functions containing fanouts keep supporting component access,
# iteration and named-tuple merging like plain fanouts:

FunctionChains.ffanoutfs(pf::PropertyFunction{<:PPaths, <:FFanout}) =
    FunctionChains.ffanoutfs(pf.sel_prop_func)

Base.iterate(pf::PropertyFunction{<:PPaths, <:FFanout}) = iterate(FunctionChains.ffanoutfs(pf))
Base.iterate(pf::PropertyFunction{<:PPaths, <:FFanout}, state) = iterate(FunctionChains.ffanoutfs(pf), state)

const _PFFanoutNT = PropertyFunction{<:PPaths, <:FFanout{<:NamedTuple}}

Base.merge(a::NamedTuple, pf::_PFFanoutNT) = merge(a, FunctionChains.ffanoutfs(pf))

Base.merge(a::_PFFanoutNT) = a
Base.merge(a::_PFFanoutNT, bs::_PFFanoutNT...) =
    FunctionChains.ffanout(merge(FunctionChains.ffanoutfs(a), map(FunctionChains.ffanoutfs, bs)...))

# For fanouts fused into pure property selections the component extraction
# functions are reconstructed from the Paths type parameter. Fused results
# are property selections rather than containers, so they don't iterate or
# merge, like other fusion results of ffanout and ffchain:

_extraction_pfs(::Type{Paths}) where {Paths<:PPaths} =
    map(P -> PropertyFunction{Tuple{P}}(P()), _paths(Paths))

FunctionChains.ffanoutfs(pf::PropertyFunction{Paths, <:_TplPropSelector}) where {Paths<:PPaths} =
    _extraction_pfs(Paths)

FunctionChains.ffanoutfs(pf::PropSelFunction{Paths, names}) where {Paths<:PPaths, names} =
    NamedTuple{names}(_extraction_pfs(Paths))

end # module
