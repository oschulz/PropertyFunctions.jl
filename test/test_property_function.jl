# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using StructArrays
using Base.Broadcast: broadcasted


struct TestStruct{T}
    apc::T
    amc::T
end


@testset "property_function" begin
    xs_sa = StructArrays.StructArray((
        a = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6],
        b = [0.1, 0.5, 0.9, 0.9, 0.9, 0.6, 0.1, 0.9, 0.8, 0.2],
        c = [0.4, 0.1, 0.4, 0.1, 0.9, 0.2, 0.4, 0.8, 0.0, 0.1]
    ))

    xs_arr = Array(xs_sa)
    xs_gen = (x for x in xs_sa)
    xs_flt = Iterators.flatten([xs_sa, xs_sa, xs_sa])

    f_real = @pf $a + $c^2
    f_real_ref(x) = x.a + x.c^2

    f_nt = @pf (apc = $a + $c, amc = $a - $c)
    f_nt_ref(x) = (apc = x.a + x.c, amc = x.a - x.c)

    f_propsel = @pf (;$b, c = $a)
    f_propsel_ref = x -> (b = x.b, c = x.a)
    @test f_propsel isa PropSelFunction{(:b, :a), (:b, :c)}
    @test f_propsel == PropSelFunction{(:b, :a), (:b, :c)}()
    @test f_propsel == PropSelFunction(:b, :a => :c)
    @test PropSelFunction{(:b, :a)}() == PropSelFunction{(:b, :a), (:b, :a)}()


    f_struct = @pf TestStruct($a + $c, $a - $c)
    f_struct_ref(x) = TestStruct(x.a + x.c, x.a - x.c)

    f_bool = @pf $a + $c^2 < 0.5
    f_bool_ref = x -> x.a + x.c^2 < 0.5

    @test @inferred(broadcast(f_real, xs_sa)) isa Vector{<:Real}
    @test @inferred(broadcast(f_nt, xs_sa)) isa StructArray
    @test @inferred(broadcast(f_propsel, xs_sa)) isa StructArray
    @test f_propsel.(xs_sa).b === xs_sa.b
    @test f_propsel.(xs_sa).c === xs_sa.a
    @test @inferred(broadcast(f_struct, xs_sa)) isa StructArray
    @test @inferred(broadcast(f_bool, xs_sa)) isa BitVector
    for xs in [xs_sa, xs_arr, xs_gen, xs_flt]
        @inferred((x -> @pf($a + $c^2)(x))(first(xs))) isa Real
        @inferred(broadcast(@pf($a + $c^2), xs)) isa AbstractArray
    
        for (f, f_ref) in [(f_real, f_real_ref), (f_nt, f_nt_ref), (f_propsel, f_propsel_ref), (f_struct, f_struct_ref), (f_bool, f_bool_ref)]
            @test @inferred(f(first(xs))) == f_ref(first(xs))
            @test @inferred(broadcast(f, xs)) == f_ref.(xs)
            if f isa PropSelFunction && xs isa StructArray
                @test @inferred(broadcasted(f, xs)) isa StructArray
            else
                @test @inferred(broadcasted(f, xs)) isa Broadcast.Broadcasted
            end
            @test @inferred(copy(broadcasted(f, xs))) == f_ref.(xs)
        end
    end

    for xs in [xs_sa, xs_arr]
        for (f, f_ref) in [(f_real, f_real_ref)]
            @test @inferred(sortby(f)(xs)) == sort(xs, by = f_ref)
        end

        for (f, f_ref) in [(f_bool, f_bool_ref)]
            @test @inferred(filterby(f)(xs)) == filter(f_ref, xs)
        end

        @test filterby(x -> x < 0.5)(broadcasted(f_real, xs)) == filter(x -> x < 0.5, f_real_ref.(xs))
        @test sortby(identity)(broadcasted(f_real, xs)) == sort(f_real_ref.(xs))

        @test @inferred(map(f_real, xs)) == map(f_real_ref, xs)
        @test map(f_nt, xs) == map(f_nt_ref, xs)
        @test @inferred(filter(f_bool, xs)) == filter(f_bool_ref, xs)
    end
    @test map(f_nt, xs_sa) isa StructArray
    @test map(f_propsel, xs_sa).b === xs_sa.b
    @test filter(@pf(42 > 0), BitVector([true, false])) == [true, false]
end


@testset "pf macro edge cases" begin
    x = (a = 1, b = 2, c = 3)
    outer = 42

    f_mixed_literal = @pf (;$c, d = 1.0)
    @test !(f_mixed_literal isa PropSelFunction)
    @test @inferred(f_mixed_literal(x)) == (c = 3, d = 1.0)

    f_mixed_expr = @pf (;$c, d = $a + 1)
    @test !(f_mixed_expr isa PropSelFunction)
    @test @inferred(f_mixed_expr(x)) == (c = 3, d = 2)

    f_outer = @pf (;$a, outer)
    @test !(f_outer isa PropSelFunction)
    @test f_outer(x) == (a = 1, outer = 42)

    f_ordered = @pf $c + $a
    @test f_ordered isa PropertyFunction{(:c, :a)}

    f_tuple = @pf ($a,)
    @test @inferred(f_tuple(x)) == (1,)

    f_const = @pf 42
    @test @inferred(f_const(x)) == 42
    @test @inferred(broadcast(f_const, StructArrays.StructArray((a = [1.0, 2.0],)))) == [42, 42]
    @test @inferred(broadcast(f_const, [0.1, 0.2])) == [42, 42]

    f_quote = @pf ($a, :(b + 1))
    @test f_quote(x) == (1, :(b + 1))

    f_interp = @pf ($a, :($($c)))
    @test f_interp(x) == (1, 3)

    f_macrocall = @pf ($a, raw"$b")
    @test f_macrocall(x) == (1, raw"$b")

    for bad_expr in [raw"@pf $1", raw"@pf $(a[1])", raw"@pf $(f(x))", raw"@pf (; c = $(a[1]))", raw"@pf (; $(f(x)))"]
        err = try macroexpand(@__MODULE__, Meta.parse(bad_expr)) catch e; e; end
        err isa LoadError && (err = err.error)
        @test err isa ArgumentError
    end
end


@testset "nested properties" begin
    inner = StructArrays.StructArray((b = [1.0, 2.0, 3.0], c = [4.0, 5.0, 6.0]))
    xs = StructArrays.StructArray((a = inner, d = [7.0, 8.0, 9.0]))
    x = xs[1]

    f_chain = @pf $a.b + $d
    @test f_chain isa PropertyFunction{((:a, :b), :d)}
    @test @inferred(f_chain(x)) == x.a.b + x.d
    @test @inferred(broadcast(f_chain, xs)) == xs.a.b .+ xs.d

    f_parens = @pf $(a.c) * 2
    @test f_parens isa PropertyFunction{((:a, :c),)}
    @test @inferred(f_parens(x)) == x.a.c * 2
    @test @inferred(broadcast(f_parens, xs)) == xs.a.c .* 2

    f_fp_chain = @fp a.b + d
    @test f_fp_chain isa PropertyFunction{((:a, :b), :d)}
    @test f_fp_chain(x) == x.a.b + x.d

    f_nestsel = @pf (;$(a.b), e = $a.c)
    @test f_nestsel isa PropSelFunction{((:a, :b), (:a, :c)), (:b, :e)}
    @test @inferred(f_nestsel(x)) == (b = x.a.b, e = x.a.c)
    @test f_nestsel.(xs).b === xs.a.b
    @test f_nestsel.(xs).e === xs.a.c

    ys = StructArrays.StructArray((a = [(b = 1, c = 2), (b = 3, c = 4)], d = [5, 6]))
    @test @inferred(broadcast(@pf($a.b + $d), ys)) == [6, 9]
    @test @inferred((@pf $a.b + $d)(ys[1])) == 6

    @test PropertyFunctions.subcolumn(xs.a, :b) === xs.a.b
    @test PropertyFunctions.subcolumn([(b = 1,), (b = 2,)], :b) == [1, 2]

    f_overlap = @pf ($a.b, $a)
    @test f_overlap isa PropertyFunction{(:a,)}
    @test @inferred(f_overlap(x)) == (x.a.b, x.a)
    @test @inferred(broadcast(f_overlap, xs)) == [(xi.a.b, xi.a) for xi in xs]
end


@testset "fp macro" begin
    x = (a = 1, b = 2, c = 3)
    c_outer = 10
    f(u) = 2u

    f_fp = @fp a + f(b) + $c_outer
    @test f_fp isa PropertyFunction{(:a, :b)}
    @test @inferred(f_fp(x)) == x.a + f(x.b) + c_outer

    @test (@fp (; b, c = a)) isa PropSelFunction{(:b, :a), (:b, :c)}
    @test (@fp (; b, c = a))(x) == (b = 2, c = 1)

    @test (@fp (a, :(q + 1), raw"$b"))(x) == (1, :(q + 1), raw"$b")
    @test (@fp Base.abs(a) + sum(sqrt.((a, c))))(x) ≈ abs(x.a) + sqrt(x.a) + sqrt(x.c)
    @test (@fp a + $(c_outer + 1))(x) == x.a + 11
    @test (@fp foldl($+, (a, b, c)))(x) == 6
    @test (@fp TestStruct(a + c, a - c))(x) == TestStruct(4, -2)

    xs = StructArrays.StructArray((a = [1.0, 2.0], b = [3.0, 4.0], c = [5.0, 6.0]))
    @test @inferred(broadcast(@fp(a + c^2), xs)) == xs.a .+ xs.c .^ 2
    @test (@fp (; c, b)).(xs).c === xs.c
end
