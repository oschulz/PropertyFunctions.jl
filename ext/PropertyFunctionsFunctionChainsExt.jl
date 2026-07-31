# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

module PropertyFunctionsFunctionChainsExt

using FunctionChains: FunctionChains, FunctionChain, ffchain
using PropertyFunctions: PropertyFunctions, PropertyFunction, PPaths

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

end # module
