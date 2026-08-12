# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

module PropertyFunctionsPartialFunctionsExt

using PartialFunctions: PartialFunctions
using PropertyFunctions: PropertyFunctions, PropertyFunction

# Fixing keyword arguments of a property function fixes its input
# properties:
PartialFunctions.:$(pf::PropertyFunction, fixed::NamedTuple) =
    PropertyFunctions.fix_input_properties(pf; fixed...)

end # module
