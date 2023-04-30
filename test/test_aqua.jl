# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

import Test
import Aqua
import PropertyFunctions

Test.@testset "Aqua tests" begin
    Aqua.test_all(PropertyFunctions)
end # testset
