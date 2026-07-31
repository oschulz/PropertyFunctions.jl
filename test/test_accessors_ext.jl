# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using StructArrays
using Accessors
using PropertyFunctions: PPath


_plus_one_nt(x) = (b = x + 1,)

@testset "accessors extension" begin
    xs = StructArray((a = StructArray((b = [1.0, 2.0], c = [3.0, 4.0])), d = [5.0, 6.0]))
    x = xs[1]

    @test PPath(@o _.d) === PPath(:d)
    @test PPath(@o _.a.b) === PPath(:a, :b)
    @test convert(PPath, @o _.a.b) === PPath(:a, :b)
    @test @inferred(convert(PPath, @o _.a.b)) === PPath(:a, :b)
    @test_throws ArgumentError PPath(@o log(_.a.b))

    pf_flat = PropertyFunction(@o _.d)
    @test pf_flat === @pf $d
    @test @inferred(pf_flat(x)) == x.d
    @test @inferred(broadcast(pf_flat, xs)) === xs.d

    pf_nested = PropertyFunction(@o _.a.b)
    @test pf_nested === @pf $a.b
    @test @inferred(pf_nested(x)) == x.a.b
    @test @inferred(broadcast(pf_nested, xs)) === xs.a.b
    @test @inferred(sortby(pf_nested)(xs)) == xs[sortperm(xs.a.b)]

    pf_func = PropertyFunction(@o log(_.a.b))
    @test pf_func isa PropertyFunction{Tuple{PPath{(:a, :b)}}}
    @test @inferred(broadcast(pf_func, xs)) ≈ log.(xs.a.b)

    pf_trailing = PropertyFunction(@o _plus_one_nt(_.d).b)
    @test pf_trailing isa PropertyFunction{Tuple{PPath{(:d,)}}}
    @test @inferred(pf_trailing(x)) == x.d + 1

    @test_throws MethodError PropertyFunction(log ∘ exp)

    @test convert(PropertyFunction, @o _.d) === pf_flat
    @test convert(PropertyFunction, @o _.a.b) === pf_nested
    @test @inferred(convert(PropertyFunction, @o _.a.b)) === pf_nested
    @test_throws MethodError convert(PropertyFunction, log ∘ exp)

    psel_flat = PropSelFunction(@o _.d)
    @test psel_flat === PropSelFunction{Tuple{PPath{(:d,)}}, (:d,)}()
    @test @inferred(psel_flat(x)) == (d = x.d,)

    psel_nested = PropSelFunction(@o _.a.b)
    @test psel_nested === PropSelFunction{Tuple{PPath{(:a, :b)}}, (:b,)}()
    @test @inferred(psel_nested(x)) == (b = x.a.b,)
    @test psel_nested.(xs).b === xs.a.b

    @test convert(PropSelFunction, @o _.a.b) === psel_nested
    @test @inferred(convert(PropSelFunction, @o _.a.b)) === psel_nested
    @test_throws ArgumentError PropSelFunction(@o log(_.a.b))
    @test_throws MethodError convert(PropSelFunction, log ∘ exp)

    x_nt = (a = (b = 1, c = 2), d = 4)

    @test @inferred(Accessors.set(x_nt, PPath(:a, :b), 10)) == (a = (b = 10, c = 2), d = 4)

    psel = @pf (;$(a.b), e = $d)
    @test @inferred(Accessors.set(x_nt, psel, (b = 10, e = 40))) == (a = (b = 10, c = 2), d = 40)
    @test Accessors.set(x_nt, psel, psel(x_nt)) == x_nt
    @test psel(Accessors.set(x_nt, psel, (b = 7, e = 8))) == (b = 7, e = 8)
    @test Accessors.modify(v -> map(w -> 10w, v), x_nt, psel) == (a = (b = 10, c = 2), d = 40)

    @test @inferred(Accessors.set(x_nt, @pf($d), 9)) == (a = (b = 1, c = 2), d = 9)
    @test Accessors.set(x_nt, @pf($(a.b)), 10) == (a = (b = 10, c = 2), d = 4)
    @test Accessors.modify(-, x_nt, @pf($d)) == (a = (b = 1, c = 2), d = -4)

    @test @inferred(Accessors.set(x_nt, @pf(($d, $(a.b))), (9, 10))) == (a = (b = 10, c = 2), d = 9)

    xs_set = Accessors.set(xs, psel, (b = [10.0, 20.0], e = [50.0, 60.0]))
    @test xs_set isa StructArray
    @test xs_set.a.b == [10.0, 20.0] && xs_set.d == [50.0, 60.0] && xs_set.a.c == xs.a.c

    xs_setcol = Accessors.set(xs, @pf($d), [9.0, 8.0])
    @test xs_setcol isa StructArray
    @test xs_setcol.d == [9.0, 8.0] && xs_setcol.a.b == xs.a.b

    pf_log = PropertyFunction(@o log(_.d))
    @test Accessors.set((d = 1.0,), pf_log, 0.0) == (d = 1.0,)
end
