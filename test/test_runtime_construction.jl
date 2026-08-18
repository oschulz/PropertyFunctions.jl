# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using Serialization
using StructArrays: StructArray

using PropertyFunctions: input_property_paths, fix_input_properties

@testset "runtime_construction" begin
    xs = StructArray((
        a = [0.9, 0.1, 0.9, 0.2, 0.7], b = [0.1, 0.5, 0.9, 0.9, 0.9],
        c = [0.4, 0.1, 0.4, 0.1, 0.9]
    ))
    x = xs[1]

    @testset "equivalence with @pf" begin
        pf = PropertyFunction(Meta.parse(raw"$a + $c^2"))
        pf_ref = @pf $a + $c^2
        @test pf isa PropertyFunction
        @test input_property_paths(pf) == input_property_paths(pf_ref)
        @test @inferred(pf(x)) == pf_ref(x)
        @test @inferred(broadcast(pf, xs)) == pf_ref.(xs)
        @test pf(a = 0.9, c = 0.4) == pf_ref(x)

        pf_bool = PropertyFunction(Meta.parse(raw"$a > 0.5 && !($b < 0.5) || $c ≈ 0.1"))
        pf_bool_ref = @pf $a > 0.5 && !($b < 0.5) || $c ≈ 0.1
        @test pf_bool.(xs) == pf_bool_ref.(xs)

        pf_cmp = PropertyFunction(Meta.parse(raw"0.0 < $a <= 0.7 ? $b : $c"))
        pf_cmp_ref = @pf 0.0 < $a <= 0.7 ? $b : $c
        @test pf_cmp.(xs) == pf_cmp_ref.(xs)

        nested = (a = (b = [1, 41, 3], c = 51.1), d = 4)
        pf_nested = PropertyFunction(Meta.parse(raw"$(a.b)[2] + $a.c + $d"))
        pf_nested_ref = @pf $(a.b)[2] + $a.c + $d
        @test input_property_paths(pf_nested) == input_property_paths(pf_nested_ref)
        @test @inferred(pf_nested(nested)) == pf_nested_ref(nested)

        pf_dot = PropertyFunction(Meta.parse(raw"$a .+ log.($b)"))
        pf_dot_ref = @pf $a .+ log.($b)
        @test pf_dot((a = [1.0, 2.0], b = [1.0, 1.0])) == pf_dot_ref((a = [1.0, 2.0], b = [1.0, 1.0]))

        @test PropertyFunction(:(1 + 2))((;)) == 3
        @test PropertyFunction(42)((;)) == 42
    end

    @testset "selections and extractions" begin
        @test PropertyFunction(Meta.parse(raw"$a")) === @pf $a
        @test PropertyFunction(Meta.parse(raw"(; $c, d = $a)")) === @pf (; $c, d = $a)
        @test PropertyFunction(Meta.parse(raw"($c, $a)")) === @pf ($c, $a)
        @test broadcast(PropertyFunction(Meta.parse(raw"$a")), xs) === xs.a
        @test broadcast(PropertyFunction(Meta.parse(raw"(; $c, d = $a)")), xs).d === xs.a
    end

    @testset "env resolution" begin
        ex = Meta.parse(raw"f($a) + b")
        pf = PropertyFunction(ex, (f = sin, b = 42, unused = 7))
        @test @inferred(pf((a = 0.0,))) == 42.0
        @test PropertyFunction(ex, Dict(:f => cos, :b => 1))((a = 0.0,)) == 2.0

        @test PropertyFunction(Meta.parse(raw"$a ± $b"), (; (:±) => (x, y) -> (x, y)))((a = 1, b = 2)) == (1, 2)
        @test PropertyFunction(Meta.parse(raw"$a .± $b"), (; (:±) => +))((a = [1, 2], b = [3, 4])) == [4, 6]
        @test PropertyFunction(Meta.parse(raw"$a in rng"), (rng = 1:3,))((a = 2,)) == true

        # Update operators carry their base operator in the expression head:
        ex_upd = Meta.parse(raw"begin s = $a; s += b; s end")
        @test PropertyFunction(ex_upd, (; b = 3, (:+) => (x, y) -> x - y))((a = 10,)) == 7

        # Names not in env resolve in the PropertyFunctions module scope:
        @test PropertyFunction(Meta.parse(raw"abs($a)"))((a = -3,)) == 3
        @test_throws UndefVarError PropertyFunction(Meta.parse(raw"no_such_function($a)"))((a = 1,))
    end

    @testset "content-based identity" begin
        pf1 = PropertyFunction(Meta.parse(raw"$a - $b"), (;))
        pf2 = PropertyFunction(Meta.parse(raw"$a - $b"), Dict{Symbol,Any}())
        @test typeof(pf1) === typeof(pf2)
        @test pf1.sel_prop_func == pf2.sel_prop_func
        @test hash(pf1.sel_prop_func) == hash(pf2.sel_prop_func)

        # Same expression, but the compiled function specializes on the env
        # value types:
        pf3 = PropertyFunction(Meta.parse(raw"f($a)"), (f = sin,))
        pf4 = PropertyFunction(Meta.parse(raw"f($a)"), (f = cos,))
        @test typeof(pf3.sel_prop_func.rgf) === typeof(pf4.sel_prop_func.rgf)
        @test typeof(pf3) !== typeof(pf4)
        @test pf3.sel_prop_func != pf4.sel_prop_func

        # == must return a Bool even for envvals containing missing:
        pf5 = PropertyFunction(Meta.parse(raw"$a + m"), (m = missing,))
        pf6 = PropertyFunction(Meta.parse(raw"$a + m"), (m = missing,))
        @test (pf5.sel_prop_func == pf6.sel_prop_func) === true
    end

    @testset "rejected expressions" begin
        @test_throws ArgumentError PropertyFunction(Meta.parse(raw"@m($a)"))
        @test_throws ArgumentError PropertyFunction(Meta.parse(raw"$a + f(_)"))
        @test_throws ArgumentError PropertyFunction(Meta.parse("var\"#pf_arg#\".b + \$a"))
        @test_throws ArgumentError PropertyFunction(Meta.parse(raw"$a + b"), Dict(Symbol("#pf_arg#") => 1, :b => 2))
    end

    @testset "serialization" begin
        pf = PropertyFunction(Meta.parse(raw"g($a) + $b"), (g = abs,))
        io = IOBuffer()
        serialize(io, pf)
        seekstart(io)
        pf2 = deserialize(io)
        @test typeof(pf2) === typeof(pf)
        @test pf2((a = -1, b = 2)) == pf((a = -1, b = 2)) == 3
    end

    @testset "generated-code cache self-heal" begin
        RGF = PropertyFunctions.RuntimeGeneratedFunctions
        cache = getfield(PropertyFunctions, RGF._cachename)

        # Simulate a downstream precompile image, which preserves the property
        # function but not the generated-code cache entry:
        pf = PropertyFunction(Meta.parse(raw"$a + 100"))
        id = PropertyFunctions._rgf_id(pf.sel_prop_func.rgf)
        @test haskey(cache, id)
        delete!(cache, id)
        @test pf((a = 1,)) == 101

        # Bodies containing closures must restore under their original id:
        pf_clsr = PropertyFunction(Meta.parse(raw"sum(v -> v + $a, 1:3)"))
        id_clsr = PropertyFunctions._rgf_id(pf_clsr.sel_prop_func.rgf)
        delete!(cache, id_clsr)
        @test pf_clsr((a = 1,)) == 9
        @test haskey(cache, id_clsr)

        # A cache entry whose weakly referenced body has been garbage
        # collected must self-heal as well:
        pf_gcd = PropertyFunction(Meta.parse(raw"$a + 200"))
        id_gcd = PropertyFunctions._rgf_id(pf_gcd.sel_prop_func.rgf)
        cache[id_gcd] = WeakRef(nothing)
        @test pf_gcd((a = 1,)) == 201
    end

    @testset "PropertyFunction integrations" begin
        pf = PropertyFunction(Meta.parse(raw"$a + $b"))
        @test fix_input_properties(pf, b = 2)((a = 1,)) == 3
        @test (xs |> filterby(PropertyFunction(Meta.parse(raw"$a > 0.5")))) == (xs |> filterby(@pf $a > 0.5))
        @test (xs |> sortby(PropertyFunction(Meta.parse(raw"$c - $a")))) == (xs |> sortby(@pf $c - $a))
    end
end
