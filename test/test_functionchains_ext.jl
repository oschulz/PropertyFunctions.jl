# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using StructArrays
using FunctionChains
using PropertyFunctions: PPath


@testset "functionchains extension" begin
    xs = StructArray((a = StructArray((b = [1.0, 2.0], c = [3.0, 4.0])), d = [5.0, 6.0]))
    x = xs[1]

    pf = @pf $a.b + $d
    fc = ffchain(pf, exp, log)
    @test fc isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test fc.sel_prop_func isa FunctionChain
    @test @inferred(fc(x)) ≈ x.a.b + x.d
    @test @inferred(broadcast(fc, xs)) ≈ xs.a.b .+ xs.d

    @test ffchain(pf, identity) === pf
    @test ffchain(identity, pf, identity) === pf

    sel1 = @pf (; x = $a.b, y = $d)
    @test ffchain(sel1, @pf($x)) === @pf $a.b
    @test ffchain(sel1, @pf($x), exp) === ffchain(@pf($a.b), exp)
    @test ffchain(sel1, @pf($x), exp)(x) == exp(x.a.b)
    @test ffchain(fchain(sel1, @pf($x)), exp)(x) == exp(x.a.b)

    @test ffcomp(exp, pf) isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test ffcomp(exp, pf)(x) == exp(x.a.b + x.d)

    v = x.a.b + x.d
    @test all(with_intermediate_results(fc, x) .≈ (v, exp(v), v))

    fc2 = ffchain(exp, pf)
    @test !(fc2 isa PropertyFunction)
    @test fc2 isa FunctionChain

    fc3 = fchain(exp, log) ∘ pf
    @test fc3 isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test fc3.sel_prop_func isa FunctionChain
    @test @inferred(fc3(x)) ≈ x.a.b + x.d
end
