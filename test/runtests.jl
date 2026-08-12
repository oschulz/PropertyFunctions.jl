# This file is a part of PropertyFunctions.jl, licensed under the MIT License (MIT).

import Test
import PropertyFunctions

Test.@testset "Package PropertyFunctions" begin
    include("test_aqua.jl")
    include("test_property_function.jl")
    include("test_filterby.jl")
    include("test_sortby.jl")
    include("test_innermerge.jl")
    include("test_accessors_ext.jl")
    include("test_functionchains_ext.jl")
    include("test_partialfunctions_ext.jl")
    # Reactant only supports 64-bit Linux and macOS, and some of its
    # dependencies break already during precompilation on other platforms,
    # so it can't be a static test dependency. Reactant testing stalls on
    # Julia v1.10 CI jobs, so skip it there as well:
    if VERSION >= v"1.11" && Sys.WORD_SIZE == 64 && (Sys.islinux() || Sys.isapple()) && isempty(VERSION.prerelease)
        import Pkg
        Base.identify_package("Reactant") === nothing && Pkg.add("Reactant")
        include("test_reactant_ext.jl")
    end
    include("test_docs.jl")
    Test.@test isempty(Test.detect_ambiguities(PropertyFunctions))
end # testset
