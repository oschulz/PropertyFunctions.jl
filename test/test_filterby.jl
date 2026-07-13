# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using Base.Broadcast: broadcasted


@testset "filterby" begin
    xs = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6]
    ref_ys = [0.1, 0.2, 0.0, 0.2]

    @test @inferred(xs |> filterby(x -> x < 0.5)) isa Array
    @test @inferred(xs |> filterby(getindex, x -> x < 0.5)) isa Array
    @test @inferred(xs |> filterby(view, x -> x < 0.5)) isa SubArray

    @test xs |> filterby(x -> x < 0.5) == ref_ys
    @test xs |> filterby(getindex, x -> x < 0.5) == ref_ys
    @test xs |> filterby(view, x -> x < 0.5) == ref_ys

    bc = broadcasted(-, xs, 0.2)
    ref_bc_ys = filter(x -> x < 0.3, xs .- 0.2)
    @test @inferred(bc |> filterby(x -> x < 0.3)) == ref_bc_ys
    @test @inferred(bc |> filterby(view, x -> x < 0.3)) == ref_bc_ys
end
