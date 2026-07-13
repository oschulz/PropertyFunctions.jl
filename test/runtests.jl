# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

import Test
import PropertyFunctions

Test.@testset "Package PropertyFunctions" begin
    include("test_aqua.jl")
    include("test_property_function.jl")
    include("test_filterby.jl")
    include("test_sortby.jl")
    include("test_docs.jl")
    Test.@test isempty(Test.detect_ambiguities(PropertyFunctions))
end # testset
