# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

# Tests for the Reactant extension. Reactant is too heavy for the default
# test matrix, so this file only runs when PROPERTYFUNCTIONS_TEST_REACTANT
# is set (see the "Reactant extension" CI job), and adds Reactant to the
# test environment on demand.

import Pkg
if isnothing(Base.find_package("Reactant"))
    Pkg.add("Reactant")
end

using PropertyFunctions
using Test

using StructArrays
using Reactant

@testset "reactant_ext" begin
    reactant_ext = Base.get_extension(PropertyFunctions, :PropertyFunctionsReactantExt)
    @test !isnothing(reactant_ext)
    @test isempty(Test.detect_ambiguities(reactant_ext))

    xs = StructArray((
        a = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6],
        b = [0.1, 0.5, 0.9, 0.9, 0.9, 0.6, 0.1, 0.9, 0.8, 0.2],
        c = [0.4, 0.1, 0.4, 0.1, 0.9, 0.2, 0.4, 0.8, 0.0, 0.1],
    ))
    rxs = Reactant.to_rarray(xs)

    f_real = @pf $a + $c^2
    @test @jit(broadcast(f_real, rxs)) ≈ f_real.(xs)

    f_nt = @pf (apc = $a + $c^2, amc = $a - $b)
    ref_nt = f_nt.(xs)
    res_nt = @jit broadcast(f_nt, rxs)
    @test res_nt isa StructArray
    @test res_nt.apc ≈ ref_nt.apc
    @test res_nt.amc ≈ ref_nt.amc

    # Nested property access:
    zs = StructArray((
        a = StructArray((b = [1.0, 2.0, 3.0], c = [4.0, 5.0, 6.0])),
        d = [7.0, 8.0, 9.0],
    ))
    rzs = Reactant.to_rarray(zs)
    f_nested = @pf (u = $a.b + $d, v = $a.c - $d)
    ref_nested = f_nested.(zs)
    res_nested = @jit broadcast(f_nested, rzs)
    @test res_nested.u ≈ ref_nested.u
    @test res_nested.v ≈ ref_nested.v
end
