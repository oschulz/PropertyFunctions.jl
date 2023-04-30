# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


struct _SortBy{
    F,
    IdxAccF<:Union{typeof(getindex),typeof(view)},
    SortAlg<:Base.Sort.Algorithm,
    Ordr<:Base.Order.Ordering
} <: Function
    f::F
    idxaccf::IdxAccF
    alg::SortAlg
    rev::Bool
    order::Ordr
end

"""
    sortby(
        [getindex|view,]
        f;
        alg::SortAlg = Base.DEFAULT_STABLE, 
        rev::Bool = false,
        order::Ordr = Base.Order.Forward
    )

Generates a function that sorts and array by `f`, returning either a copy
(default) or a view (ignored if the object does not support views).

Example:
```julia
xs = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6]
xs |> sortby(x -> (x - 0.5)^2)
```
"""
function sortby end
export sortby

sortby(
    accfunc::Union{typeof(getindex),typeof(view)},
    f;
    alg::Base.Sort.Algorithm = Base.DEFAULT_STABLE, 
    rev::Bool = false,
    order::Base.Order.Ordering = Base.Order.Forward
) = _SortBy(f, accfunc, alg, rev, order)

sortby(f; kwargs...) = sortby(getindex, f; kwargs...)


@inline function (srt::_SortBy)(xs::Union{AbstractArray,Base.Broadcast.Broadcasted})
    key = srt.f.(xs)
    idxs = sortperm(key, alg = srt.alg, rev = srt.rev, order = srt.order)
    srt.idxaccf(xs, idxs)
end
