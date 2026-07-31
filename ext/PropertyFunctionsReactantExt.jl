# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

module PropertyFunctionsReactantExt

using Reactant: Reactant
using Reactant.TracedRArrayOverrides: AbstractReactantArrayStyle
using StructArrays: StructArrayStyle
using PropertyFunctions: _PropsNTKernel, _props_structarray
using Base.Broadcast: Broadcasted

# Reactant currently can't materialize multi-argument broadcasts of
# struct-returning functions, but handles the equivalent broadcast over a
# single StructArray argument. So run the property-function broadcast kernel
# over a zero-copy StructArray of the referenced columns instead.
#
# This extension is a temporary workaround and will become unnecessary once
# Reactant supports such broadcasts natively (upstream fix in progress). It
# relies on the Reactant-internal name TracedRArrayOverrides, so it may
# require adjustment for future Reactant releases. If it fails to load,
# PropertyFunctions itself remains fully functional:
function Base.copy(
    bc::Broadcasted{StructArrayStyle{S,N}, <:Any, <:_PropsNTKernel}
) where {S<:AbstractReactantArrayStyle, N}
    return broadcast(bc.f.sel_prop_func, _props_structarray(bc.f, bc.args))
end

end # module
