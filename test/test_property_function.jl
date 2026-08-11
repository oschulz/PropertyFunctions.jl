# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using PropertyFunctions
using Test

using StructArrays
using Base.Broadcast: broadcasted
using PropertyFunctions: PPath
using SparseArrays: SparseVector
using FillArrays: Fill


struct TestStruct{T}
    apc::T
    amc::T
end


# A non-callable model type participating in input calls f(_) via the
# input_property_paths/call_on interface, with a positional-style body:
struct PFTestModel
    offset::Float64
end
PropertyFunctions.input_property_paths(::PFTestModel) = (PPath(:mu), PPath(:sigma))
PropertyFunctions.call_on(m::PFTestModel, x) = m.offset + x.mu * x.sigma

_take_last(ex) = ex.args[end]


@testset "ppath" begin
    x = (a = (b = 1, c = 2), d = 3)

    @test PPath(:d) === PPath{(:d,)}()
    @test PPath(:a, :b) === PPath{(:a, :b)}()
    @test @inferred(PPath(:d)(x)) == 3
    @test @inferred(PPath(:a, :b)(x)) == 1
end


@testset "construction validation" begin
    @test_throws ArgumentError PPath()
    @test_throws ArgumentError PPath{()}()
    @test_throws ArgumentError PPath{(1,)}()

    @test_throws ArgumentError PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:a, :b)}}}(identity)
    @test_throws ArgumentError PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:a,)}}}(identity)
    @test_throws ArgumentError PropertyFunction{Tuple{PPath{()}}}(identity)

    @test_throws ArgumentError PropSelFunction(PPath(:a), PPath(:a, :b) => :b)
    @test_throws ArgumentError PropSelFunction(:a, :a)
    @test_throws ArgumentError PropSelFunction(:a => :c, :b => :c)
    @test_throws ArgumentError PropSelFunction{Tuple{PPath{(:a,)}}, (:x, :y)}()
    @test_throws ArgumentError PropSelFunction{Tuple{PPath{()}}}()

    @test PropertyFunction{Tuple{}}(x -> 42) isa PropertyFunction{Tuple{}}
    @test PropSelFunction(:c, PPath(:a, :b) => :d) isa
        PropSelFunction{Tuple{PPath{(:c,)}, PPath{(:a, :b)}}, (:c, :d)}
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
    @test f_propsel isa PropSelFunction{Tuple{PPath{(:b,)}, PPath{(:a,)}}, (:b, :c)}
    @test f_propsel == PropSelFunction{Tuple{PPath{(:b,)}, PPath{(:a,)}}, (:b, :c)}()
    @test f_propsel == PropSelFunction(:b, :a => :c)
    @test PropSelFunction{Tuple{PPath{(:b,)}, PPath{(:a,)}}}() ==
        PropSelFunction{Tuple{PPath{(:b,)}, PPath{(:a,)}}, (:b, :a)}()
    @test @pf((b = $b, c = $a)) === f_propsel

    f_extract = @pf $a
    f_extract_ref = x -> x.a
    @test f_extract isa PropertyFunction{Tuple{PPath{(:a,)}}, PPath{(:a,)}}
    @test f_extract.(xs_sa) === xs_sa.a

    f_tplsel = @pf ($b, $a)
    f_tplsel_ref = x -> (x.b, x.a)
    @test @inferred(broadcast(f_tplsel, xs_sa)) isa StructArray
    @test StructArrays.components(f_tplsel.(xs_sa))[1] === xs_sa.b
    @test StructArrays.components(f_tplsel.(xs_sa))[2] === xs_sa.a

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

        for (f, f_ref) in [(f_real, f_real_ref), (f_nt, f_nt_ref), (f_propsel, f_propsel_ref), (f_extract, f_extract_ref), (f_tplsel, f_tplsel_ref), (f_struct, f_struct_ref), (f_bool, f_bool_ref)]
            @test @inferred(f(first(xs))) == f_ref(first(xs))
            @test @inferred(broadcast(f, xs)) == f_ref.(xs)
            if f.sel_prop_func isa PropertyFunctions._PropSelector && xs isa StructArray
                @test !(@inferred(broadcasted(f, xs)) isa Broadcast.Broadcasted)
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


@testset "input calls" begin
    x = (a = 2.0, mu = 3.0, sigma = 0.5)
    f = @pf $mu * $sigma

    make_g(f) = @pf $a + f(_)
    g = @inferred make_g(f)
    @test g isa PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:mu,)}, PPath{(:sigma,)}}}
    @test @inferred(g(x)) == x.a + x.mu * x.sigma

    xs = StructArrays.StructArray((
        a = [2.0, 3.0], mu = [1.0, 2.0], sigma = [0.5, 0.25], unused = [0, 0]
    ))
    @test @inferred(broadcast(g, xs)) == xs.a .+ xs.mu .* xs.sigma

    # Overlapping properties merge into the minimal cover:
    g_dedup = @pf $mu + f(_)
    @test g_dedup isa PropertyFunction{Tuple{PPath{(:mu,)}, PPath{(:sigma,)}}}
    @test g_dedup(x) == x.mu + x.mu * x.sigma

    xn = (a = (b = 1, c = 2), d = 3)
    f_nested = @pf $a.b + $d
    # Paths of the expression itself come first, then input-call paths:
    g_nested = @pf f_nested(_) - $(a.c)
    @test g_nested isa PropertyFunction{Tuple{PPath{(:a, :c)}, PPath{(:a, :b)}, PPath{(:d,)}}}
    @test g_nested(xn) == xn.a.b + xn.d - xn.a.c
    g_cover = @pf ($a, f_nested(_))
    @test g_cover isa PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:d,)}}}
    @test g_cover(xn) == (xn.a, f_nested(xn))

    # PPath callees:
    p = PPath(:mu)
    g_ppath = @pf p(_) + $a
    @test g_ppath isa PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:mu,)}}}
    @test g_ppath(x) == x.mu + x.a

    # Quote interpolation inside a callee is evaluated at hoist time,
    # non-colliding names are fine:
    @test (@pf _take_last(quote $f end)(_)) === f

    # An input call as the entire expression short-circuits, PPath callees
    # keep the zero-copy broadcast optimization:
    @test (@pf f(_)) === f
    @test (@pf p(_)) isa PropertyFunction{Tuple{PPath{(:mu,)}}, PPath{(:mu,)}}
    @test (@pf p(_)).(xs) === xs.mu

    # _ in binding positions stays available:
    @test (@pf (_ -> $a)(nothing))(x) == x.a
    @test (@pf sum($a for _ in 1:3))(x) == 3 * x.a

    # Other function-like types participate via input_property_paths/call_on:
    m = PFTestModel(10.0)
    pf_m = @pf m(_)
    @test pf_m isa PropertyFunction{Tuple{PPath{(:mu,)}, PPath{(:sigma,)}}}
    @test pf_m(x) == 10.0 + x.mu * x.sigma
    @test (@pf $a * m(_))(x) == x.a * (10.0 + x.mu * x.sigma)

    # Callee expressions are evaluated once, at construction:
    cnt = Ref(0)
    counting_f() = (cnt[] += 1; f)
    g_cnt = @pf counting_f()(_) + $a
    @test cnt[] == 1
    @test g_cnt(x) == f(x) + x.a
    @test cnt[] == 1

    # Functions without input_property_paths are rejected at construction:
    @test_throws ArgumentError @pf $a + sin(_)

    # Input-call callees are hoisted out and evaluated at construction, so
    # callees that use names bound inside the expression must be rejected
    # (issue found in review):
    g_local = @pf begin s = f(_); s + $a end
    @test g_local isa PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:mu,)}, PPath{(:sigma,)}}}
    @test g_local(x) == f(x) + x.a

    # Input calls are discovered through quote interpolations, quoted
    # macro calls are inert data, but their quote interpolations are live:
    @test (@pf :($(f(_))))(x) == f(x)
    q_and_m = @pf (f(_), :(@somemacro 1))
    @test q_and_m(x)[1] == f(x)
    q_m_interp = @pf (f(_), :(@somemacro $(1 + 1)))
    @test q_m_interp(x)[1] == f(x)

    # Quote interpolation is depth-sensitive, a single $ inside nested
    # quotes only unquotes one level, so input calls only activate at
    # quote depth zero:
    g_nested_inert = @pf quote quote $(f(_)) end end
    @test g_nested_inert isa PropertyFunction{Tuple{}}
    @test g_nested_inert(x) isa Expr
    g_nested_active = @pf quote quote $$(f(_)) end end
    @test g_nested_active isa PropertyFunction{Tuple{PPath{(:mu,)}, PPath{(:sigma,)}}}
    @test g_nested_active(x) isa Expr

    # Invalid input-call callees are rejected at macro expansion:
    for bad_expr in [
        raw"@pf $f(_)",
        raw"@pf f(_)(_)",
        raw"@pf let f = inner; f(_) end",
        raw"@pf begin f = inner; f(_) end",
        raw"@pf (f -> f(_))(g)",
        raw"@pf quote $(let f = inner; f(_) end) end",
        raw"@pf quote quote $$(let f = inner; f(_) end) end end",
        raw"@pf f(_) + @show($a)",
        raw"@pf begin f = inner; unquote_last(quote $f end)(_) end",
        raw"@pf (@somemacro())(_)",
        raw"@pf begin quote @somemacro $(f = inner) end; f(_) end",
    ]
        err = try macroexpand(@__MODULE__, Meta.parse(bad_expr)) catch e; e; end
        err isa LoadError && (err = err.error)
        @test err isa ArgumentError
    end

    # Other rvalue uses of _ are rejected by Julia itself:
    for bad_expr in [raw"@pf _", raw"@pf $a + _", raw"@pf f(_, 1)"]
        err = try Core.eval(@__MODULE__, Meta.parse(bad_expr)) catch e; e; end
        err isa LoadError && (err = err.error)
        @test err isa ErrorException
    end
end


@testset "map and filter fallbacks" begin
    # The map and filter specializations are restricted to StructArray, so
    # array types with their own map and filter specializations, like sparse
    # and fill arrays, must dispatch to those without method ambiguities:
    sv = SparseVector(5, [2, 4], [1.0 + 2.0im, 3.0 + 4.0im])
    @test map(@pf(2 * $re), sv) == 2 .* real.(sv)
    @test filter(@pf($re > 2), sv) == [3.0 + 4.0im]

    fl = Fill((a = 1, b = 2), 3)
    @test map(@pf($a + $b), fl) == fill(3, 3)
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

    f_eqform_expr = @pf (c = $c, d = $a + 1)
    @test !(f_eqform_expr isa PropSelFunction)
    @test @inferred(f_eqform_expr(x)) == (c = 3, d = 2)

    f_outer = @pf (;$a, outer)
    @test !(f_outer isa PropSelFunction)
    @test f_outer(x) == (a = 1, outer = 42)

    f_ordered = @pf $c + $a
    @test f_ordered isa PropertyFunction{Tuple{PPath{(:c,)}, PPath{(:a,)}}}

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
    @test f_chain isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test @inferred(f_chain(x)) == x.a.b + x.d
    @test @inferred(broadcast(f_chain, xs)) == xs.a.b .+ xs.d

    f_parens = @pf $(a.c) * 2
    @test f_parens isa PropertyFunction{Tuple{PPath{(:a, :c)}}}
    @test @inferred(f_parens(x)) == x.a.c * 2
    @test @inferred(broadcast(f_parens, xs)) == xs.a.c .* 2

    f_extract = @pf $a.b
    @test f_extract === @pf $(a.b)
    @test @inferred(f_extract(x)) == x.a.b
    @test @inferred(broadcast(f_extract, xs)) === xs.a.b
    @test (@pf $d).(xs) === xs.d

    f_tplsel = @pf ($d, $a.b)
    @test @inferred(f_tplsel(x)) == (x.d, x.a.b)
    @test @inferred(broadcast(f_tplsel, xs)) == [(xi.d, xi.a.b) for xi in xs]
    @test StructArrays.components(f_tplsel.(xs))[2] === xs.a.b

    f_nestsel = @pf (;$(a.b), e = $a.c)
    @test @pf((b = $(a.b), e = $a.c)) === f_nestsel
    @test f_nestsel isa PropSelFunction{Tuple{PPath{(:a, :b)}, PPath{(:a, :c)}}, (:b, :e)}
    @test @inferred(f_nestsel(x)) == (b = x.a.b, e = x.a.c)
    @test f_nestsel.(xs).b === xs.a.b
    @test f_nestsel.(xs).e === xs.a.c
    @test PropSelFunction(PPath(:a, :b) => :b, PPath(:a, :c) => :e) === f_nestsel

    ys = StructArrays.StructArray((a = [(b = 1, c = 2), (b = 3, c = 4)], d = [5, 6]))
    @test @inferred(broadcast(@pf($a.b + $d), ys)) == [6, 9]
    @test @inferred((@pf $a.b + $d)(ys[1])) == 6

    @test PropertyFunctions.subcolumn(xs.a, :b) === xs.a.b
    @test PropertyFunctions.subcolumn([(b = 1,), (b = 2,)], :b) == [1, 2]
    @test PropertyFunctions.subcolumn(xs.a, Val(:b)) === xs.a.b
    @test @inferred(PropertyFunctions.subcolumn([(b = 1, c = 2.0)], Val(:c))) == [2.0]

    # Nested properties of a non-StructArray column with differing field types
    # are only type-stable if the property name is in the type domain:
    zs = StructArrays.StructArray((a = [(b = 1, c = 2.0), (b = 3, c = 4.0)], d = [5, 6]))
    @test @inferred(broadcast(@pf($a.c * $d), zs)) == [10.0, 24.0]

    f_overlap = @pf ($a.b, $a)
    @test f_overlap isa PropertyFunction{Tuple{PPath{(:a,)}}}
    @test !(f_overlap.sel_prop_func isa PropertyFunctions._PropSelector)
    @test @inferred(f_overlap(x)) == (x.a.b, x.a)
    @test @inferred(broadcast(f_overlap, xs)) == [(xi.a.b, xi.a) for xi in xs]

    f_overlap_sel = @pf (;$a, c = $a.c)
    @test !(f_overlap_sel isa PropSelFunction)
    @test f_overlap_sel(x) == (a = x.a, c = x.a.c)
end


@testset "composition" begin
    inner = StructArrays.StructArray((b = [1.0, 2.0, 3.0], c = [4.0, 5.0, 6.0]))
    xs = StructArrays.StructArray((a = inner, d = [7.0, 8.0, 9.0]))
    x = xs[1]

    @test PPath(:b) ∘ PPath(:a) === PPath(:a, :b)

    f_c = exp ∘ @pf($a.b + $d)
    @test f_c isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test @inferred(f_c(x)) == exp(x.a.b + x.d)
    @test @inferred(broadcast(f_c, xs)) == exp.(xs.a.b .+ xs.d)

    f_c2 = log ∘ f_c
    @test f_c2 isa PropertyFunction{Tuple{PPath{(:a, :b)}, PPath{(:d,)}}}
    @test @inferred(f_c2(x)) ≈ x.a.b + x.d

    sel1 = @pf (; x = $a.b, y = $d)
    @test @inferred(@pf($x) ∘ sel1) === @pf $a.b
    @test @inferred(@pf((; u = $x, v = $y)) ∘ sel1) === @pf (; u = $a.b, v = $d)
    @test @inferred(@pf(($y, $x)) ∘ sel1) === @pf ($d, $a.b)
    @test (@pf $x.c) ∘ @pf((; x = $a)) === @pf $a.c
    @test (@pf $b) ∘ @pf($a) === @pf $a.b
    @test ((@pf $x) ∘ sel1).(xs) === xs.a.b

    f_pfpf = @pf($q + 1) ∘ @pf((; q = $a.b))
    @test f_pfpf isa PropertyFunction{Tuple{PPath{(:a, :b)}}}
    @test @inferred(f_pfpf(x)) == x.a.b + 1

    f_bad = @pf($z) ∘ @pf((; x = $a))
    @test f_bad isa PropertyFunction{Tuple{PPath{(:a,)}}}
    @test_throws Exception f_bad(x)

    f_tpl = @pf($x) ∘ @pf(($a, $d))
    @test f_tpl isa PropertyFunction{Tuple{PPath{(:a,)}, PPath{(:d,)}}}
end
