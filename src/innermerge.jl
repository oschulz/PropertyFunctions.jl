# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).


"""
    innermerge(tbl, tbls...)

Merge the columns of table-like objects, with columns of later tables
taking precedence (like `merge` for `NamedTuple`s).

Tries to preserve the table type of `tbl`, but returns a
`StructArrays.StructArray` where the result would otherwise be a
row-oriented table.

Example:

```julia
xs = StructArrays.StructArray((a = [1, 2], b = [3, 4]))
ys = innermerge(xs, (c = [5, 6],))
ys.a === xs.a
```

`innermerge` may be specialized for table types with expensive column
access (e.g. lazy or on-disk tables).
"""
function innermerge end
export innermerge

innermerge(tbl, tbls...) =
    _tbl_materializer(tbl)(merge(_cols_as_nt(tbl), map(_cols_as_nt, tbls)...))

_cols_as_nt(tbl) = _as_nt(Tables.columns(tbl))
_as_nt(cols::NamedTuple) = cols
_as_nt(cols) = Tables.columntable(cols)

_tbl_materializer(tbl) = _postproc_materializer(Tables.materializer(tbl))
_postproc_materializer(f_materializer) = f_materializer
_postproc_materializer(::typeof(Tables.rowtable)) = StructArray
