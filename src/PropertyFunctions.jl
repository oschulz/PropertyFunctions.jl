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

include("filterby.jl")
include("sortby.jl")
include("property_function.jl")

end # module
