# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test


@testset "sortby" begin
    xs = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6]
    ref_ys = [0.5, 0.6, 0.7, 0.7, 0.2, 0.2, 0.9, 0.1, 0.9, 0.0]

    @test @inferred(xs |> sortby(x -> (x - 0.5)^2)) isa Array
    @test @inferred(xs |> sortby(getindex, x -> (x - 0.5)^2)) isa Array
    @test @inferred(xs |> sortby(view, x -> (x - 0.5)^2)) isa SubArray

    @test xs |> sortby(x -> (x - 0.5)^2) == ref_ys
    @test xs |> sortby(getindex, x -> (x - 0.5)^2) == ref_ys
    @test xs |> sortby(view, x -> (x - 0.5)^2) == ref_ys
end
