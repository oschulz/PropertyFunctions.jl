# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

using Test
using PropertyFunctions
import Documenter

Documenter.DocMeta.setdocmeta!(
    PropertyFunctions,
    :DocTestSetup,
    :(using PropertyFunctions);
    recursive=true,
)
Documenter.doctest(PropertyFunctions)
