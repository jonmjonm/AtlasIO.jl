# AtlasIO 0.2 (JSON.jl): value types on write and read, and the public API added in 0.2
# (parseMap, mapJSON, mapBytes). Uses helpers from v1_fixtures.jl (typedEqual, readAllMaps, FIXDIR, ...).

using Dates

# The value `x` of `data["x"]` as written, for a one-key data Dict (so the bytes don't depend on Dict order).
function writtenValue(x)
    s = mapJSON(Map{Dict{String,Any}}("m", Districting(), 1, Dict{String,Any}("x" => x)))
    return s[findfirst("\"x\":", s)[end]+1:findlast(",\"districting\"", s)[1]-2]
end

struct TACustom
    a::Int
end
@enum TAColor ta_red ta_green

@testset verbose = true "AtlasIO 0.2: value types and new API" begin

    @testset "write: every value type is written exactly as AtlasIO 0.1.5 (JSON3) wrote it" begin
        # Expected strings were measured with AtlasIO 0.1.5 on 2026-11-23. Where JSON.jl's default differs
        # (Rational, DateTime/Time fractions, arrays of 2+ dimensions), AtlasStyle restores the 0.1.5 form.
        cases = [
            Int8(-5) => "-5", Int32(7) => "7", UInt8(200) => "200",
            typemax(UInt64) => "18446744073709551615",
            Int128(2)^100 => "1267650600228229401496703205376",
            big(10)^30 => "1000000000000000000000000000000",
            0.1f0 => "0.1", Float16(0.5) => "0.5",
            big"0.1" => "0.1000000000000000000000000000000000000000000000000000000000000000000000000000002",
            1//3 => "0.3333333333333333", π => "3.141592653589793",
            missing => "null", nothing => "null", :sym => "\"sym\"", 'c' => "\"c\"",
            Date(2026, 11, 23) => "\"2026-11-23\"",
            DateTime(2026, 11, 23, 1, 2, 3) => "\"2026-11-23T01:02:03.0\"",
            DateTime(2026, 11, 23, 1, 2, 3, 45) => "\"2026-11-23T01:02:03.045\"",
            Time(1, 2, 3) => "\"01:02:03.0\"", Time(1, 2, 3, 500) => "\"01:02:03.5\"",
            Day(3) => "{\"value\":3}",
            (1, "a") => "[1,\"a\"]", (a=1, b=2.0) => "{\"a\":1,\"b\":2.0}", Set([3]) => "[3]",
            TACustom(1) => "{\"a\":1}", ta_red => "\"ta_red\"", 1 + 2im => "{\"re\":1,\"im\":2}",
            Int8[1, 2] => "[1,2]", 1:3 => "[1,2,3]", view([1, 2, 3], 2:3) => "[2,3]",
            Any[1, "a", nothing] => "[1,\"a\",null]", [[1, 2], [3]] => "[[1,2],[3]]",
            [1 2; 3 4] => "[1,3,2,4]", [1.5 2.5] => "[1.5,2.5]", zeros(Int, 0, 2) => "[]",
            reshape(1:8, 2, 2, 2) => "[1,2,3,4,5,6,7,8]", [[1 2; 3 4]] => "[[1,3,2,4]]",
        ]
        for (x, want) in cases
            @test writtenValue(x) == want
        end
        @test_throws Exception writtenValue(Inf)       # not valid JSON (0.1.5 threw too)
        @test_throws Exception writtenValue(NaN)
    end

    @testset "read: number and container types are exact" begin
        line = "{\"name\":\"m\",\"weight\":2,\"data\":{\"f\":0.0,\"one\":1.0,\"i\":1,\"neg0\":-0.0," *
               "\"big\":9007199254740993,\"max\":9223372036854775807,\"huge\":123456789012345678901234567890," *
               "\"nested\":{\"v\":[1,2.5,{\"x\":null}]},\"s\":\"é\"},\"districting\":[{\"[\\\"A\\\"]\":1}]}"
        for d in (parseMap(line, Dict{String,Any}).data, parseMapData(line, Dict{String,Any}).data)
            @test d["f"] === 0.0                         # 0.1.x read Int 0
            @test d["one"] === 1.0                       # 0.1.x read Int 1
            @test d["i"] === 1
            @test d["neg0"] === -0.0                     # 0.1.x read 0
            @test d["big"] === 9007199254740993          # 2^53 + 1, exact (0.1.x lost it)
            @test d["max"] === typemax(Int64)
            @test d["huge"] isa BigInt && d["huge"] == big"123456789012345678901234567890"
            @test d isa Dict{String,Any}
            @test d["nested"] isa Dict{String,Any}
            @test d["nested"]["v"] isa Vector{Any}
            @test d["nested"]["v"][3] isa Dict{String,Any} && d["nested"]["v"][3]["x"] === nothing
            @test d["s"] === "é"
        end

        atlas, maps = readAllMaps(joinpath(FIXDIR, "edge.jsonl"))
        @test typeof(maps[1]) === Map{Dict{String,Any},Int64}
        @test atlas.atlasParam isa Dict{String,Any}
        @test atlas.atlasParam["nested"] isa Dict{String,Any}
        @test atlas.atlasParam["gamma"] === 0.0          # 0.1.x read Int 0 (broke Measure(gamma::Float64) in MFRecom)
        @test atlas.description isa String && atlas.date isa String

        fatlas, fmaps = readAllMaps(joinpath(FIXDIR, "edge_float.jsonl"))
        @test fatlas.weightType === Float64
        @test all(m -> m isa Map{Dict{String,Any},Float64}, fmaps)
        @test fmaps[2].weight === 2.0
    end

    @testset "mapJSON / mapBytes / addMap agree" begin
        m = Map{Dict{String,Any}}("m", Districting(("a\"b", "c\\d") => 1, ("é",) => 2), 3,
                                  Dict{String,Any}("x" => [0.0, 1//3]))
        s = mapJSON(m)
        @test s isa String && !endswith(s, "\n")
        @test mapBytes(m) == Vector{UInt8}(s * "\n")
        io = IOBuffer()
        @test addMap(io, m) == length(mapBytes(m))       # returns the number of bytes written
        @test take!(io) == mapBytes(m)
        # JSON.json without AtlasIO's style still writes the v1 map layout (only the Rational differs).
        @test occursin("\"districting\":[{", JSON.json(m))
    end

    @testset "parseMap" begin
        m = Map{Dict{String,Any}}("m", Districting(("A",) => 1, ("B", "p1") => 2), 3, Dict{String,Any}("x" => 0.5))
        back = parseMap(mapJSON(m), Dict{String,Any})
        @test back isa Map{Dict{String,Any},Int64}
        @test back.name == m.name && back.weight == m.weight && back.districting == m.districting
        @test typedEqual(back.data, m.data)
        @test parseMap(String(mapBytes(m)), Dict{String,Any}).districting == m.districting   # trailing "\n" is fine
        fw = parseMap(mapJSON(Map{Dict{String,Any}}("f", Districting(), 0.25, Dict{String,Any}())), Dict{String,Any}, Float64)
        @test fw isa Map{Dict{String,Any},Float64} && fw.weight === 0.25
        @test_throws AtlasFormatError parseMap("not json", Dict{String,Any})
        @test_throws AtlasFormatError parseMap("{\"name\":\"m\"}", Dict{String,Any})
    end

    @testset "writeMaps!(out, mapBytes.(maps)) writes the same atlas as addMaps" begin
        _, maps = readAllMaps(joinpath(FIXDIR, "edge.jsonl"))
        header = AtlasHeader("w", "2026-11-23T00:00:00", "Dict{String, Any}", "Dict{String, Any}")
        ref = IOBuffer()
        newAtlas(ref, header, Dict{String,Any}())
        addMaps(ref, maps)
        refBytes = take!(ref)
        hdr = IOBuffer(); newAtlas(hdr, header, Dict{String,Any}()); hdrBytes = take!(hdr)
        for ext in (".jsonl", ".jsonl.gz")
            path = tempname() * ext
            out = openAtlasOutput(path, hdrBytes)
            writeMaps!(out, mapBytes.(maps))
            close(out)
            got = ext == ".jsonl" ? read(path) : transcode(GzipDecompressor, read(path))
            @test got == refBytes
            rm(path)
        end
    end

    @testset "single-pass districting writer is byte-identical to the reference writer" begin
        rng = Xoshiro(7)
        # Includes characters the fast path escapes inline (" and \), ones it hands to the reference path
        # (control characters, DEL), and multi-byte UTF-8.
        chars = vcat(collect("aZ09 ,[]{}:'/\"\\éñ中😀"), ['\t', '\n', '\x01', '\x1f', '\x7f'])
        rname() = String(rand(rng, chars, rand(rng, 0:6)))
        bad = 0
        for _ in 1:500
            d = Districting()
            for _ in 1:rand(rng, 0:30)
                d[Tuple(rname() for _ in 1:rand(rng, 1:3))] = rand(rng, (0, 7, 42, 999, 1000, 123456, -3))
            end
            bad += AtlasIO.districtingJSON(d).value != AtlasIO._districtingJSONReference(d).value
        end
        @test bad == 0
        _, nc = readAllMaps(joinpath(REPO_ROOT, "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl"))
        @test all(AtlasIO.districtingJSON(m.districting).value == AtlasIO._districtingJSONReference(m.districting).value for m in nc)
        # Control characters in names still round-trip (written through the reference path).
        m = Map{Dict{String,Any}}("c", Districting(("tab\there", "nl\n") => 1, ("del\x7f",) => 2), 1, Dict{String,Any}())
        @test parseMap(mapJSON(m), Dict{String,Any}).districting == m.districting
    end

    @testset "parseDistrictKey decodes every JSON escape (0.1.x mis-decoded all but \\\" and \\\\)" begin
        pk = AtlasIO.parseDistrictKey
        @test pk("[\"37011\", \"1\"]") == ("37011", "1")
        @test pk("[\"a\\\"b\", \"c\\\\d\"]") == ("a\"b", "c\\d")          # AtlasIO's own escapes (fast path)
        @test pk("[\"DO\\u00d1A ANA\"]") == ("DOÑA ANA",)                  # Python json.dumps default
        @test pk("[\"tab\\there\", \"nl\\nx\"]") == ("tab\there", "nl\nx")
        @test pk("[\"\\ud83d\\ude00\"]") == ("😀",)                        # surrogate pair
        @test pk("[\"B\",\"p1\"]") == ("B", "p1")                          # no space after the comma
        @test pk("[\"x, y\", \"[br]\"]") == ("x, y", "[br]")
    end
end

# The Atlas constructors that callers written before AtlasIO 0.2.1 use (no formatVersion; before float weights, no
# weightType either). CycleWalk 0.2.5 calls the typed six-argument form; MetropolizedForestRecom the typed five.
@testset "Atlas constructors kept for older callers" begin
    P = Dict{String,Any}
    param = P("a" => 1)
    io = IOBuffer()
    for (a, weightType) in (
            (Atlas{P}(io, "d", "t", param, P, Float64), Float64),       # typed, six arguments
            (Atlas(io, "d", "t", param, P, Float64), Float64),          # untyped, six
            (Atlas{P}(io, "d", "t", param, P), Int64))                  # typed, five: weights default to Int64
        @test a isa Atlas{P}
        @test a.io === io && a.description == "d" && a.date == "t" && a.atlasParam === param
        @test a.mapParamType === P && a.weightType === weightType
        @test a.formatVersion == "1"
    end
    @test Atlas{P}(io, "d", "t", param, P, Float64, "2").formatVersion == "2"
end
