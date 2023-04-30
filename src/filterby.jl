# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


struct _FilterBy{
    F,
    IdxAccF<:Union{typeof(getindex),typeof(view)}
} <: Function
    f::F
    idxaccf::IdxAccF
end

"""
    filterby([getindex|view,] f)

Generates a function that filters a table-like array by `f`, returning
either a copy (default) or a view (ignored if the object does not support
views).

Example:
```julia
xs = [0.9, 0.1, 0.9, 0.2, 0.7, 0.0, 0.7, 0.5, 0.2, 0.6]
xs |> filterby(x -> x < 0.5)
```
"""
function filterby end
export filterby

filterby(
    accfunc::Union{typeof(getindex),typeof(view)},
    f
) = _FilterBy(f, accfunc)

filterby(f) = filterby(getindex, f)


function(flt::_FilterBy)(xs::Union{AbstractArray,Base.Broadcast.Broadcasted})
    flt.idxaccf(xs, flt.f.(xs)::AbstractArray{Bool})
end
