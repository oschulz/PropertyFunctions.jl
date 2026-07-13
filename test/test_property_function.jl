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
    end
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

    f_tuple = @pf ($a,)
    @test @inferred(f_tuple(x)) == (1,)

    f_const = @pf 42
    @test @inferred(f_const(x)) == 42

    f_quote = @pf ($a, :(b + 1))
    @test f_quote(x) == (1, :(b + 1))

    f_interp = @pf ($a, :($($c)))
    @test f_interp(x) == (1, 3)

    f_macrocall = @pf ($a, raw"$b")
    @test f_macrocall(x) == (1, raw"$b")

    for bad_expr in [raw"@pf $(a.b)", raw"@pf (; c = $(a.b))", raw"@pf (; $(a.b))"]
        err = try macroexpand(@__MODULE__, Meta.parse(bad_expr)) catch e; e; end
        err isa LoadError && (err = err.error)
        @test err isa ArgumentError
    end
end
