# Use
#
#     DOCUMENTER_DEBUG=true julia --color=yes make.jl local [nonstrict] [fixdoctests]
#
# for local builds.

using Documenter
using PropertyFunctions

# Doctest setup
DocMeta.setdocmeta!(
    PropertyFunctions,
    :DocTestSetup,
    :(using PropertyFunctions);
    recursive=true,
)

makedocs(
    sitename = "PropertyFunctions",
    modules = [PropertyFunctions],
    format = Documenter.HTML(
        prettyurls = !("local" in ARGS),
        canonical = "https://oschulz.github.io/PropertyFunctions.jl/stable/"
    ),
    pages = [
        "Home" => "index.md",
        "API" => "api.md",
        "LICENSE" => "LICENSE.md",
    ],
    doctest = ("fixdoctests" in ARGS) ? :fix : true,
    linkcheck = !("nonstrict" in ARGS),
    strict = !("nonstrict" in ARGS),
)

deploydocs(
    repo = "github.com/oschulz/PropertyFunctions.jl.git",
    forcepush = true,
    push_preview = true,
)
