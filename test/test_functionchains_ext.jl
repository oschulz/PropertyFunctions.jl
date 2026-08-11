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

    # A fanout of property functions becomes a property function:
    ff1 = @pf $a.b * 2
    ff2 = @pf $d + $a.b
    ffo = ffanout(ff1, ff2)
    @test ffo isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test ffo.sel_prop_func isa FFanout
    @test @inferred(ffo(x)) == (ff1(x), ff2(x))
    @test @inferred(broadcast(ffo, xs)) == tuple.(ff1.(xs), ff2.(xs))
    @test ffanout((ff1, ff2)) == ffo
    ffo_nt = ffanout(u = ff1, v = ff2)
    @test ffo_nt isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test ffo_nt(x) == (u = ff1(x), v = ff2(x))
    @test ffanout(ff1, exp) isa FFanout

    # Fanouts work as input-call callees:
    h = @pf ffanout(ff1, ff2)(_)[1] + $d
    @test h isa PropertyFunction{Tuple{PPath{(:d,)}, PPath{(:a, :b)}}}
    @test h(x) == ff1(x) + x.d

    # Fanout results keep supporting component access, iteration and
    # named-tuple merging:
    @test @inferred(ffanoutfs(ffo)) == (ff1, ff2)
    @test (ffo...,) == (ff1, ff2)
    @test ffanoutfs(ffo_nt) == (u = ff1, v = ff2)
    @test (; ffo_nt...) == (u = ff1, v = ff2)
    @test @inferred(ffanoutfs(ffanout(@pf($a.b), @pf($d)))) == (@pf($a.b), @pf($d))
    @test ffanoutfs(ffanout(u = @pf($a.b), v = @pf($d))) == (u = @pf($a.b), v = @pf($d))
    @test merge(ffo_nt) === ffo_nt
    ff3 = @pf $d * 3
    ffo_merged = merge(ffo_nt, ffanout(w = ff3))
    @test ffanoutfs(ffo_merged) == (u = ff1, v = ff2, w = ff3)
    @test ffo_merged(x) == (u = ff1(x), v = ff2(x), w = ff3(x))

    # Fanouts of pure extractions with disjoint paths fuse into property
    # selections that broadcast zero-copy:
    @test ffanout(@pf($a.b), @pf($d)) === @pf ($a.b, $d)
    @test StructArrays.components(broadcast(ffanout(@pf($a.b), @pf($d)), xs))[1] === xs.a.b
    @test ffanout(u = @pf($a.b), v = @pf($d)) === @pf (u = $a.b, v = $d)
    @test ffanout(u = @pf($a.b), v = @pf($d)).(xs).u === xs.a.b

    # Overlapping extraction paths fall back to a generic fanout:
    ffo_dup = ffanout(@pf($d), @pf($d))
    @test ffo_dup isa PropertyFunction{Tuple{PPath{(:d,)}}}
    @test ffo_dup.sel_prop_func isa FFanout
    @test ffo_dup(x) == (x.d, x.d)
end
