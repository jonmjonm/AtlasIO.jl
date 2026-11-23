# Test F, step 3 of 3: read the files written by the CURRENT AtlasIO (step 1) with AtlasIO 0.1.5, and compare
# with the independent expected values (step 2). Run it in an environment that has AtlasIO 0.1.5 and JSON:
#
#     julia --project=ENV -e 'import Pkg; Pkg.add([Pkg.PackageSpec(name="AtlasIO", version="0.1.5"),
#                                                  Pkg.PackageSpec(name="JSON")])'
#     julia --project=ENV test/compat/read_with_0_1_5.jl OUTDIR
#
# 0.1.5's Map and atlas-parameter read paths parse every number as a Float64 (a known 0.1.x bug), so there
# values are compared with `==` and integers beyond 2^53 are masked; whole-number floats then compare equal to
# 0.1.5's Ints. Its nextMapData path is exact, so it is compared without masking.

using Test
using AtlasIO
import JSON

pkgversion(AtlasIO) == v"0.1.5" || error("read_with_0_1_5.jl must run with AtlasIO 0.1.5, found $(pkgversion(AtlasIO))")
length(ARGS) == 1 || error("usage: julia --project=ENV test/compat/read_with_0_1_5.jl OUTDIR")
const OUT = ARGS[1]
const EXPECTED = JSON.parse(read(joinpath(OUT, "expected.json"), String); dicttype = Dict{String,Any})

plainval(x::AbstractDict) = Dict{String,Any}(string(k) => plainval(v) for (k, v) in x)
plainval(x::AbstractVector) = Any[plainval(v) for v in x]
plainval(x) = x
const LIMIT = big(2)^53
isbeyond(x) = (x isa Integer && !(x isa Bool) && abs(big(x)) > LIMIT) ||
              (x isa AbstractFloat && isfinite(x) && isinteger(x) && abs(big(x)) > LIMIT)
mask(x::AbstractDict) = Dict{String,Any}(string(k) => mask(v) for (k, v) in x)
mask(x::AbstractVector) = Any[mask(v) for v in x]
mask(x) = isbeyond(x) ? :beyond_2_53 : x
districting(pairs) = Dict{Tuple{Vararg{String}},Int64}(Tuple(String.(p[1])) => p[2] for p in pairs)

@testset "test F: AtlasIO 0.1.5 reads files written by the current AtlasIO" begin
    @testset "$name" for name in sort(collect(keys(EXPECTED)))
        exp = EXPECTED[name]
        path = joinpath(OUT, name)

        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        maps = Map[]
        while !eof(atlas)
            push!(maps, nextMap(atlas))
        end
        close(io)
        @test atlas.description == exp["header"]["description"]
        @test atlas.date == exp["header"]["date"]
        @test mask(plainval(atlas.atlasParam)) == mask(exp["atlasParam"])
        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test m.weight == em["weight"]
            @test mask(plainval(m.data)) == mask(em["data"])
            @test m.districting == districting(em["districting"])
        end

        io = smartOpen(path, "r")
        atlas = openAtlas(io)
        md = MapData[]
        while !eof(atlas)
            push!(md, nextMapData(atlas))
        end
        close(io)
        @test [plainval(x.data) for x in md] == [em["data"] for em in exp["maps"]]   # exact, no masking

        io = smartOpen(path, "r")
        threaded = nextMaps(openAtlas(io); batch = 3)
        close(io)
        @test [x.districting for x in threaded] == [m.districting for m in maps]
    end
end
