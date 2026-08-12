# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using PartialFunctions
using PropertyFunctions: PPath


@testset "partialfunctions extension" begin
    f = @pf $mu * $sigma

    g = f $ (; sigma = 0.5)
    @test g isa PropertyFunction{Tuple{PPath{(:mu,)}}}
    @test g((mu = 3.0,)) == 1.5
    @test PropertyFunctions.unfix_input_properties(g) === f

    # Other argument forms keep the generic PartialFunctions behavior:
    @test !(identity $ (; x = 1) isa PropertyFunction)
end
