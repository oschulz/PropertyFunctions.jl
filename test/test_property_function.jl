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

    f_struct = @pf TestStruct($a + $c, $a - $c)
    f_struct_ref(x) = TestStruct(x.a + x.c, x.a - x.c)

    f_bool = @pf $a + $c^2 < 0.5
    f_bool_ref = x -> x.a + x.c^2 < 0.5

    @test @inferred(broadcast(f_real, xs_sa)) isa Vector{<:Real}
    if VERSION >= v"1.8"
        @test @inferred(broadcast(f_nt, xs_sa)) isa StructArray
    else
        @test (broadcast(f_nt, xs_sa)) isa StructArray
    end
    @test @inferred(broadcast(f_struct, xs_sa)) isa StructArray
    @test @inferred(broadcast(f_bool, xs_sa)) isa BitVector

    for xs in [xs_sa, xs_arr, xs_gen, xs_flt]
        @inferred((x -> @pf($a + $c^2)(x))(first(xs))) isa Real
        @inferred(broadcast(@pf($a + $c^2), xs)) isa AbstractArray
    
        for (f, f_ref) in [(f_real, f_real_ref), (f_nt, f_nt_ref), (f_struct, f_struct_ref), (f_bool, f_bool_ref)]
            @test @inferred(f(first(xs))) == f_ref(first(xs))
            if VERSION >= v"1.8"
                @test @inferred(broadcast(f, xs)) == f_ref.(xs)
            else
                @test (broadcast(f, xs)) == f_ref.(xs)
            end
            @test @inferred(broadcasted(f, xs)) isa Broadcast.Broadcasted
            if VERSION >= v"1.8"
                @test @inferred(copy(broadcasted(f, xs))) == f_ref.(xs)
            else
                @test (copy(broadcasted(f, xs))) == f_ref.(xs)
            end
        end
    end

    for xs in [xs_sa, xs_arr]
        for (f, f_ref) in [(f_real, f_real_ref)]
            @test @inferred(sortby(f)(xs)) == sort(xs, by = f_ref)
        end

        for (f, f_ref) in [(f_bool, f_bool_ref)]
            @test @inferred(filterby(f)(xs)) == filter(f_ref, xs)
        end
    end
end
