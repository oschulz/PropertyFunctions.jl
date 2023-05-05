# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


struct _SortBy{
    F,
    IdxAccF<:Union{typeof(getindex),typeof(view)},
} <: Function
    f::F
    idxaccf::IdxAccF
    rev::Bool
end


"""
    sortby(
        [getindex|view,]
        f;
        rev::Bool = false,
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

# Note: Don't offer `alg` and `order`, as these kwargs don't seem to be supported by sort on GPU.

sortby(
    accfunc::Union{typeof(getindex),typeof(view)},
    f;
    rev::Bool = false,
) = _SortBy(f, accfunc, rev)

sortby(f; kwargs...) = sortby(getindex, f; kwargs...)


@inline function (srt::_SortBy)(xs::Union{AbstractArray,Base.Broadcast.Broadcasted})
    key = srt.f.(xs)
    idxs = sortperm(key, rev = srt.rev)
    srt.idxaccf(xs, idxs)
end
