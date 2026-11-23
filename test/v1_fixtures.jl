# Tests that pin the v1 Atlas format, so later versions (the JSON.jl migration, format v2) can be checked
# against what AtlasIO 0.1.5 actually wrote and read.
#
#   * test/fixtures/v1/ holds FROZEN files written by AtlasIO 0.1.5 (JSON3) plus one written by Python.
#     See test/fixtures/README.md; they must never be regenerated with a newer AtlasIO.
#   * test/fixtures/v1/expected.json comes from an independent reader (Python's json), not from AtlasIO.
#   * Comparisons are by VALUE, not type (0 == 0.0): whole-number floats are expected to change from Int to
#     Float64 when AtlasIO moves to JSON.jl. Type checks belong to that migration.
#   * Byte-exact checks cover only output whose order is fixed (single-entry Dicts, the header line),
#     because Dict iteration order may differ between Julia versions.

import JSON
import SHA
using Random: Xoshiro

const FIXDIR = joinpath(@__DIR__, "fixtures", "v1")
const REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const EXPECTED = JSON.parse(read(joinpath(FIXDIR, "expected.json"), String); dicttype = Dict{String,Any})

const BANNER = "\"This is an Atlas for Redistricting Maps. See 'https://github.com/jonmjonm/AtlasIO.jl/blob/main/" *
               "atlas_format.md' for more information about the format.\""

"Recursively convert any JSON-ish value to plain Dict{String,Any}/Vector{Any}, so values compare by value."
plainval(x::AbstractDict) = Dict{String,Any}(string(k) => plainval(v) for (k, v) in x)
plainval(x::AbstractVector) = Any[plainval(v) for v in x]
plainval(x) = x

# KNOWN v1 BUG (AtlasIO 0.1.5): the Map and atlas-parameter read paths (JSON3 into Dict{String,Any}) parse
# every number as a Float64, so integers beyond 2^53 lose precision (typemax(Int64) reads as 9.223372036854776e18,
# -7375463094308724563 as -7375463094308724736) and -0.0 reads as 0. nextMapData/parseMapData read them exactly.
# JSON.jl reads all of these exactly, so the @test_broken checks below must flip to @test after that migration.
const EXACT_INT_LIMIT = big(2)^53
isBigInt(::Bool) = false
isBigInt(x::Integer) = abs(big(x)) > EXACT_INT_LIMIT
isBigInt(x::AbstractFloat) = isfinite(x) && isinteger(x) && abs(big(x)) > EXACT_INT_LIMIT
isBigInt(_) = false
hasBigInt(x::AbstractDict) = any(hasBigInt, values(x))
hasBigInt(x::AbstractVector) = any(hasBigInt, x)
hasBigInt(x) = isBigInt(x)
"Replace integers beyond 2^53 by a marker, so everything else can still be compared exactly."
maskBigInts(x::AbstractDict) = Dict{String,Any}(string(k) => maskBigInts(v) for (k, v) in x)
maskBigInts(x::AbstractVector) = Any[maskBigInts(v) for v in x]
maskBigInts(x) = isBigInt(x) ? :beyond_2_53 : x

"Expected districting from expected.json: a list of [key-parts, district] pairs."
expectedDistricting(pairs) = Dict{Tuple{Vararg{String}},Int64}(Tuple(String.(p[1])) => p[2] for p in pairs)

"Order-independent fingerprint of a districting; must match make_expected.py's districting_digest."
districtingDigest(d) = bytes2hex(SHA.sha256(join(sort([join(k, "\x1f") * "\x1e" * string(v) for (k, v) in d]), "\n")))

"The v1 district-key string: a JSON-style list whose items are separated by \", \", escaping only \" and \\."
v1KeyString(k) = "[" * join(("\"" * replace(s, "\\" => "\\\\", "\"" => "\\\"") * "\"" for s in k), ", ") * "]"

"JSON string literal for text without control characters (the only escapes needed are \" and \\)."
jsonStr(s) = "\"" * replace(s, "\\" => "\\\\", "\"" => "\\\"") * "\""

function readAllMaps(path)
    io = smartOpen(path, "r")
    atlas = openAtlas(io)
    maps = Map[]
    while !eof(atlas)
        push!(maps, nextMap(atlas))
    end
    close(io)
    return atlas, maps
end

function readAllMapData(path)
    io = smartOpen(path, "r")
    atlas = openAtlas(io)
    out = MapData[]
    while !eof(atlas)
        push!(out, nextMapData(atlas))
    end
    close(io)
    return out
end

function readAllThreaded(path)
    io = smartOpen(path, "r")
    atlas = openAtlas(io)
    maps = nextMaps(atlas; batch = 2)
    close(io)
    return maps
end

oneLine(m) = (io = IOBuffer(); addMap(io, m); String(take!(io)))

@testset verbose = true "v1 format (frozen fixtures from AtlasIO 0.1.5)" begin

    @testset "fixture $fname" for fname in sort(collect(keys(EXPECTED["fixtures"])))
        exp = EXPECTED["fixtures"][fname]
        path = joinpath(FIXDIR, fname)
        atlas, maps = readAllMaps(path)

        h = exp["header"]
        @test atlas.description == h["description"]
        @test atlas.date == h["date"]
        @test string(atlas.weightType) == get(h, "weightType", "Int64")
        @test plainval(atlas.atlasParam) == exp["atlasParam"]

        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test m.weight == em["weight"]
            if hasBigInt(em["data"])
                @test_broken plainval(m.data) == em["data"]                       # known v1 bug, see above
                @test maskBigInts(plainval(m.data)) == maskBigInts(em["data"])   # everything else is exact
            else
                @test plainval(m.data) == em["data"]
            end
            want = expectedDistricting(em["districting"])
            if em["julia_0_1_5_misdecodes_keys"]
                # parseDistrictKey drops the backslash of \uXXXX escapes inside keys (keys written by Python's
                # json with ensure_ascii=True). Flip to @test when that bug is fixed.
                @test_broken m.districting == want
            else
                @test m.districting == want
            end
        end

        # The other read paths. nextMapData reads numbers exactly (no 2^53 loss), so compare it to expected.json.
        md = readAllMapData(path)
        @test [x.name for x in md] == [m.name for m in maps]
        @test [x.weight for x in md] == [m.weight for m in maps]
        @test [plainval(x.data) for x in md] == [em["data"] for em in exp["maps"]]
        threaded = readAllThreaded(path)
        @test [x.name for x in threaded] == [m.name for m in maps]
        @test [x.districting for x in threaded] == [m.districting for m in maps]
    end

    @testset "real data: NC truncated multiscale atlas" begin
        exp = EXPECTED["nc_truncated"]
        path = joinpath(REPO_ROOT, exp["path"])
        # If this fails, the example file changed: regenerate expected.json only if the change is intended.
        @test bytes2hex(SHA.sha256(read(path))) == exp["sha256"]
        @test exp["ends_with_newline"] == false      # real v1 files may lack the final newline; reading must cope

        atlas, maps = readAllMaps(path)
        @test atlas.description == exp["header"]["description"]
        @test atlas.date == exp["header"]["date"]
        @test plainval(atlas.atlasParam) == exp["atlasParam"]
        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test m.weight == em["weight"]
            @test plainval(m.data) == em["data"]
            @test length(m.districting) == em["n_districting"]
            @test districtingDigest(m.districting) == em["districting_digest"]
        end
    end

    @testset "byte-exact output where order is fixed" begin
        io = IOBuffer()
        newAtlas(io, AtlasHeader("d", "t", "A", "M"), Dict{String,Any}("k" => 1))
        hdr = String(take!(io))
        @test hdr == BANNER * "\n" *
                     "{\"description\":\"d\",\"date\":\"t\",\"atlasParamType\":\"A\",\"mapParamType\":\"M\",\"weightType\":\"Int64\"}\n" *
                     "{\"k\":1}\n"

        # One-entry districting with awkward names: the exact v1 key encoding.
        for (name, k) in [("plain", ("37011", "1")), ("quote and backslash", ("a\"b", "c\\d")),
                          ("é", ("é",)), ("中文 😀", ("中文", "😀")), ("comma", ("x, y",)),
                          ("brackets", ("[br]",)), ("apostrophe", ("it's",)), ("three levels", ("p3", "c7", "b100"))]
            m = Map{Dict{String,Any}}(name, Districting(k => 5), 3, Dict{String,Any}())
            @test oneLine(m) == "{\"name\":$(jsonStr(name)),\"weight\":3,\"data\":{}," *
                                "\"districting\":[{$(jsonStr(v1KeyString(k))):5}]}\n"
        end

        # Number and string formatting inside data (one key, so the order is fixed).
        d1(x) = Map{Dict{String,Any}}("m", Districting(), 1, Dict{String,Any}("x" => x))
        prefix = "{\"name\":\"m\",\"weight\":1,\"data\":{\"x\":"
        suffix = "},\"districting\":[]}\n"
        @test oneLine(d1([0.1, 1e-7, 1e20, 1e300, 5e-324, -0.0, 1.0, 123456789.0, 2.5e15, 0.0])) ==
              prefix * "[0.1,1.0e-7,1.0e20,1.0e300,5.0e-324,-0.0,1.0,1.23456789e8,2.5e15,0.0]" * suffix
        @test oneLine(d1([typemax(Int64), typemin(Int64), 0, -1])) ==
              prefix * "[9223372036854775807,-9223372036854775808,0,-1]" * suffix
        @test oneLine(d1(Any[true, false, nothing, "s", Any[], Dict{String,Any}()])) ==
              prefix * "[true,false,null,\"s\",[],{}]" * suffix
        @test oneLine(d1("line1\nline2\ttabbed \"q\" é \\")) ==
              prefix * "\"line1\\nline2\\ttabbed \\\"q\\\" é \\\\\"" * suffix

        # Weights.
        w(x) = oneLine(Map{Dict{String,Any}}("m", Districting(), x, Dict{String,Any}()))
        @test w(0) == "{\"name\":\"m\",\"weight\":0,\"data\":{},\"districting\":[]}\n"
        @test w(0.5) == "{\"name\":\"m\",\"weight\":0.5,\"data\":{},\"districting\":[]}\n"
        @test w(2.0) == "{\"name\":\"m\",\"weight\":2.0,\"data\":{},\"districting\":[]}\n"
        @test w(1e-300) == "{\"name\":\"m\",\"weight\":1.0e-300,\"data\":{},\"districting\":[]}\n"

        # NaN can't be written as JSON; the exact exception type is allowed to change.
        @test_throws Exception oneLine(d1(NaN))
    end

    @testset "line structure of multi-entry maps (order-independent)" begin
        _, maps = readAllMaps(joinpath(FIXDIR, "edge.jsonl"))
        for m in maps
            line = oneLine(m)
            @test endswith(line, "}\n") && count(==('\n'), line) == 1
            obj = JSON.parse(line)                               # order-preserving JSON.Object
            @test collect(keys(obj)) == ["name", "weight", "data", "districting"]
            entries = obj["districting"]
            @test entries isa AbstractVector
            @test all(e -> length(e) == 1, entries)               # one single-key object per entry
            got = Dict(only(keys(e)) => only(values(e)) for e in entries)
            @test got == Dict(v1KeyString(k) => v for (k, v) in m.districting)
        end
    end

    @testset "randomized write/read round trip (names without control characters)" begin
        rng = Xoshiro(20261122)
        chars = collect("aZ09 \"\\,[]{}:'/éñ中😀")
        rname() = String(rand(rng, chars, rand(rng, 1:8)))
        maps = Map{Dict{String,Any}}[]
        for i in 1:200
            d = Districting()
            for _ in 1:rand(rng, 0:25)
                d[Tuple(rname() for _ in 1:rand(rng, 1:3))] = rand(rng, 1:20)
            end
            # Integers stay within ±2^53: larger ones hit the known v1 precision bug (tested separately below).
            data = Dict{String,Any}("f" => [rand(rng) * 10.0^rand(rng, -8:8) for _ in 1:3],
                                    "i" => rand(rng, -2^53:2^53, 2), "s" => rname())
            push!(maps, Map{Dict{String,Any}}(rname(), d, rand(rng, 1:10), data))
        end
        path = tempname() * ".jsonl"
        io = open(path, "w")
        newAtlas(io, AtlasHeader("fuzz", "2026-11-22T00:00:00", "Dict{String, Any}", "Dict{String, Any}"), Dict{String,Any}())
        addMaps(io, maps)
        close(io)

        _, back = readAllMaps(path)
        @test length(back) == length(maps)
        bad = [i for i in eachindex(maps) if !(back[i].name == maps[i].name && back[i].weight == maps[i].weight &&
                                              back[i].districting == maps[i].districting &&
                                              plainval(back[i].data) == plainval(maps[i].data))]
        isempty(bad) || @info "round-trip mismatches (first shown)" first_index = first(bad) original = maps[first(bad)] read_back = back[first(bad)]
        @test isempty(bad)
        @test [x.districting for x in readAllThreaded(path)] == [m.districting for m in maps]
        @test [plainval(x.data) for x in readAllMapData(path)] == [plainval(m.data) for m in maps]
        rm(path)
    end

    @testset "known v1 number-reading bugs (fixed by JSON.jl: flip these to @test then)" begin
        atlas, maps = readAllMaps(joinpath(FIXDIR, "edge.jsonl"))
        m = maps[1]
        @test_broken m.data["ints"][1] === typemax(Int64)        # reads as 9.223372036854776e18
        @test_broken isequal(m.data["floats"][6], -0.0)           # sign of -0.0 lost (reads as 0)

        seed = -7375463094308724563
        line = chomp(oneLine(Map{Dict{String,Any}}("b", Districting(), 1, Dict{String,Any}("seed" => seed))))
        @test occursin("\"seed\":$seed", line)                    # writing is exact
        @test_broken parseBufferToMap(atlas, String(line)).data["seed"] == seed   # Map read path loses it
        @test parseMapData(String(line), Dict{String,Any}).data["seed"] == seed  # MapData path is exact today

        # Atlas parameters (line 3) go through the same lossy path.
        io = IOBuffer()
        newAtlas(io, AtlasHeader("d", "t", "A", "M"), Dict{String,Any}("seed" => seed))
        a = openAtlas(IOBuffer(take!(io)))
        @test_broken a.atlasParam["seed"] == seed
    end
end
