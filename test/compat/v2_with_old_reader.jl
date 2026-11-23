# Old readers on v2 files fail safely (atlas_format.md, "Compatibility between versions"). Run it in an
# environment with an AtlasIO that predates v2 (0.1.5 or 0.2.0) and JSON:
#
#     julia --project=ENV test/compat/v2_with_old_reader.jl
#
# Checks, for every v2 fixture: the header opens; nextMap raises AtlasFormatError (so no wrong districting is
# ever returned); nextMapData and skipMap, which never look at the assignment, still read every map.

using Test
using AtlasIO
import JSON

const V = pkgversion(AtlasIO)
V in (v"0.1.5", v"0.2.0") || error("v2_with_old_reader.jl must run with AtlasIO 0.1.5 or 0.2.0, found $V")
const V2DIR = joinpath(@__DIR__, "..", "fixtures", "v2")
const V1EXP = JSON.parse(read(joinpath(V2DIR, "..", "v1", "expected.json"), String); dicttype = Dict{String,Any})
const V2EXP = JSON.parse(read(joinpath(V2DIR, "expected.json"), String); dicttype = Dict{String,Any})

expectedMaps(name) = name == "spec_examples.jsonl" ? V2EXP["spec_examples"]["maps"] :
                     (src = V2EXP["twins"][name]; src == "nc_truncated" ? V1EXP["nc_truncated"]["maps"] :
                                                                         V1EXP["fixtures"][src]["maps"])

@testset "AtlasIO $V on v2 files fails safely" begin
    @testset "$name" for name in sort(collect(keys(V2EXP["sha256"])))
        names = [m["name"] for m in expectedMaps(name)]
        path = joinpath(V2DIR, name)

        io = smartOpen(path, "r")
        atlas = openAtlas(io)                         # the header opens (formatVersion is just another string)
        n = 0
        while !eof(atlas)
            @test_throws AtlasFormatError nextMap(atlas)
            n += 1
        end
        close(io)
        @test n == length(names)

        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        got = String[]
        while !eof(atlas)
            push!(got, nextMapData(atlas).name)
        end
        close(io)
        @test got == names

        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        skipMap(atlas; numSkip = length(names))
        @test eof(atlas)
        close(io)
    end
end
