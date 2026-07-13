# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using StructArrays


@testset "innermerge" begin
    xs = StructArray((a = [1, 2], b = [3, 4]))
    ys = StructArray((b = [5, 6], c = [7, 8]))

    merged = @inferred innermerge(xs, ys)
    @test merged isa StructArray
    @test merged.a === xs.a
    @test merged.b === ys.b
    @test merged.c === ys.c

    @test innermerge(xs) == xs

    rowtbl = [(a = 1, b = 2), (a = 3, b = 4)]
    merged_rowtbl = innermerge(rowtbl, (c = [5, 6],))
    @test merged_rowtbl isa StructArray
    @test merged_rowtbl == StructArray((a = [1, 3], b = [2, 4], c = [5, 6]))

    coltbl = (a = [1, 2],)
    merged_coltbl = @inferred innermerge(coltbl, (b = [3, 4],))
    @test merged_coltbl isa NamedTuple
    @test merged_coltbl == (a = [1, 2], b = [3, 4])
end
