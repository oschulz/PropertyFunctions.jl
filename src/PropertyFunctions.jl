# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

"""
    PropertyFunctions

Provides functionality for easy access to and efficient broadcasting over properties.
"""
module PropertyFunctions

using Base.Broadcast: BroadcastFunction, BroadcastStyle

import Tables
import StructArrays

using StructArrays: StructArray

using RuntimeGeneratedFunctions: RuntimeGeneratedFunctions, RuntimeGeneratedFunction

include("filterby.jl")
include("sortby.jl")
include("innermerge.jl")
include("property_function.jl")
include("runtime_construction.jl")

VERSION >= v"1.11" && eval(Meta.parse("public PPath, PPaths, subcolumn, input_property_paths, fix_input_properties, unfix_input_properties, unfixed"))

end # module
