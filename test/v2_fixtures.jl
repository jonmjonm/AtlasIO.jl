# Reading format v2 (atlas_format.md, "v2: assignment"). Uses helpers from v1_fixtures.jl.
#
#   * test/fixtures/v2/ holds v2 TWINS of the frozen v1 fixtures, made by make_v2_fixtures.py with Python's json
#     (not AtlasIO): the same file with the header's "formatVersion":"2" and each districting written as a tree.
#     A twin must read back to exactly the values of its v1 source, so it is checked against v1/expected.json.
#   * spec_examples.jsonl holds the spec's own v2 examples, with keys written out by hand in the generator.
#   * The rejection tests below cover the spec's reader rules and the version checks.

const V2DIR = joinpath(@__DIR__, "fixtures", "v2")
const EXPECTED_V2 = JSON.parse(read(joinpath(V2DIR, "expected.json"), String); dicttype = Dict{String,Any})

"Read every map of the atlas in `text` (a String) with nextMap."
readText(text) = (a = openAtlas(IOBuffer(text)); m = Map[]; while !eof(a); push!(m, nextMap(a)); end; (a, m))

const V2_HEADER = """{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M","formatVersion":"2"}"""
const V1_HEADER = """{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M"}"""
v2Atlas(lines...; header = V2_HEADER) = join(["\"banner\"", header, "{}", lines...], "\n") * "\n"
mapLine(assignment) = """{"name":"x","weight":1,"data":{},"assignment":$assignment}"""

@testset verbose = true "v2 format (reading)" begin

    @testset "files are the ones expected.json describes" begin
        for (name, h) in EXPECTED_V2["sha256"]
            @test bytes2hex(SHA.sha256(read(joinpath(V2DIR, name)))) == h
        end
    end

    @testset "twin $fname reads exactly like its v1 source" for fname in sort(collect(keys(EXPECTED["fixtures"])))
        exp = EXPECTED["fixtures"][EXPECTED_V2["twins"][fname]]
        path = joinpath(V2DIR, fname)
        atlas, maps = readAllMaps(path)
        @test atlas.formatVersion == "2"
        @test atlas.description == exp["header"]["description"]
        @test atlas.date == exp["header"]["date"]
        @test string(atlas.weightType) == get(exp["header"], "weightType", "Int64")
        @test typedEqual(atlas.atlasParam, exp["atlasParam"])
        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test typedEqual(m.weight, atlas.weightType(em["weight"]))
            @test typedEqual(m.data, em["data"])
            @test m.districting == expectedDistricting(em["districting"])
        end
        # And the same as AtlasIO reads the v1 file, through every read path.
        _, v1maps = readAllMaps(joinpath(FIXDIR, fname))
        @test [m.districting for m in maps] == [m.districting for m in v1maps]
        md = readAllMapData(path)
        @test [x.name for x in md] == [m.name for m in maps]
        @test all(typedEqual(x.data, em["data"]) for (x, em) in zip(md, exp["maps"]))
        @test [x.districting for x in readAllThreaded(path)] == [m.districting for m in maps]
    end

    @testset "real data: NC truncated multiscale atlas (v2 twin)" begin
        exp = EXPECTED["nc_truncated"]
        atlas, maps = readAllMaps(joinpath(V2DIR, "nc_truncated.jsonl.gz"))
        @test atlas.formatVersion == "2"
        @test typedEqual(atlas.atlasParam, exp["atlasParam"])
        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test typedEqual(m.data, em["data"])
            @test length(m.districting) == em["n_districting"]
            @test districtingDigest(m.districting) == em["districting_digest"]
        end
        _, v1maps = readAllMaps(joinpath(REPO_ROOT, exp["path"]))
        @test [m.districting for m in maps] == [m.districting for m in v1maps]
    end

    @testset "the spec's examples" begin
        exp = EXPECTED_V2["spec_examples"]
        atlas, maps = readAllMaps(joinpath(V2DIR, "spec_examples.jsonl"))
        @test atlas.formatVersion == "2"
        @test atlas.atlasParam["levels in graph"] == ["county", "mcd", "prec_id"]
        @test length(maps) == length(exp["maps"])
        for (m, em) in zip(maps, exp["maps"])
            @test m.name == em["name"]
            @test m.districting == expectedDistricting(em["districting"])
        end
        @test maps[2].districting == Districting(("WAKE",) => 3, ("MECKLENBURG", "DAVIDSON") => 12,
                                                 ("MECKLENBURG", "CHARLOTTE", "052") => 13,
                                                 ("MECKLENBURG", "CHARLOTTE", "074") => 14)
        @test isempty(maps[3].districting)
        @test maps[4].districting[("a\tb", "c\nd")] == 2 && maps[4].districting[("", "")] == 1
    end

    @testset "formatVersion in the header" begin
        @test openAtlas(IOBuffer(v2Atlas(; header = V1_HEADER))).formatVersion == "1"     # absent means v1
        h1 = """{"description":"d","date":"t","atlasParamType":"A","mapParamType":"M","formatVersion":"1"}"""
        @test openAtlas(IOBuffer(v2Atlas(; header = h1))).formatVersion == "1"
        @test openAtlas(IOBuffer(v2Atlas())).formatVersion == "2"
        # A version this AtlasIO doesn't know: a clear error, never a guess.
        h3 = replace(V2_HEADER, "\"2\"" => "\"3\"")
        err = try openAtlas(IOBuffer(v2Atlas(; header = h3))); nothing catch e; e end
        @test err isa AtlasFormatError && occursin("formatVersion \"3\"", err.msg) && occursin("Upgrade AtlasIO", err.msg)
        # Header values must be strings ("formatVersion":2 is a number).
        hn = replace(V2_HEADER, "\"2\"" => "2")
        err = try openAtlas(IOBuffer(v2Atlas(; header = hn))); nothing catch e; e end
        @test err isa AtlasFormatError && occursin("\"formatVersion\" must be a JSON string", err.msg)
        # An Atlas built the pre-0.2.1 way (no formatVersion) means v1.
        a = Atlas(IOBuffer(), "d", "t", Dict{String,Any}(), Dict{String,Any}, Int64)
        @test a.formatVersion == "1"
    end

    @testset "reader rejects what the spec forbids" begin
        bad = Dict(
            "empty branch (rule 3)" => mapLine("""{"A":{"p1":1},"B":{}}"""),
            "empty branch, deeper" => mapLine("""{"A":{"t":{}}}"""),
            "boolean district" => mapLine("""{"A":true}"""),
            "float district" => mapLine("""{"A":2.0}"""),
            "string district" => mapLine("""{"A":"2"}"""),
            "null district" => mapLine("""{"A":null}"""),
            "array district" => mapLine("""{"A":[2]}"""),
            "district beyond Int64" => mapLine("""{"A":99999999999999999999}"""),
            "assignment not an object" => mapLine("[]"),
            "assignment is a number" => mapLine("3"),
            "both fields" => """{"name":"x","weight":1,"data":{},"districting":[],"assignment":{}}""",
            "neither field" => """{"name":"x","weight":1,"data":{}}""",
            "not an object" => "[1,2]",
        )
        @testset "$label" for (label, line) in bad
            @test_throws AtlasFormatError parseMap(line, Dict{String,Any})
            a = openAtlas(IOBuffer(v2Atlas(line)))
            @test_throws AtlasFormatError nextMap(a)
        end
        err = try parseMap(mapLine("""{"A":{}}"""), Dict{String,Any}); nothing catch e; e end
        @test occursin("empty branch", err.msg) && occursin("(map \"x\")", err.msg)
    end

    @testset "a file holds one version: lines must match the header" begin
        v1line = """{"name":"old","weight":1,"data":{},"districting":[{"[\\"A\\"]":1}]}"""
        v2line = mapLine("""{"A":1}""")
        # Each parses on its own (parseMap accepts either version)...
        @test parseMap(v1line, Dict{String,Any}).districting == parseMap(v2line, Dict{String,Any}).districting
        # ...but not inside an atlas whose header declares the other version.
        for (header, line) in [(V2_HEADER, v1line), (V1_HEADER, v2line)]
            text = v2Atlas(line; header = header)
            err = try nextMap(openAtlas(IOBuffer(text))); nothing catch e; e end
            @test err isa AtlasFormatError && occursin("a file holds maps of one version only", err.msg)
            @test_throws AtlasFormatError nextMaps(openAtlas(IOBuffer(text)))
            a = openAtlas(IOBuffer(text))
            @test_throws AtlasFormatError parseBufferToMap(a, String(line))
            # nextMapData never looks at the assignment, so it still reads the line.
            @test nextMapData(openAtlas(IOBuffer(text))).name in ("old", "x")
        end
    end

    @testset "skipMap, nextMapData and EOF on v2 files" begin
        a = openAtlas(IOBuffer(v2Atlas(mapLine("""{"A":1}"""), mapLine("""{"B":{"c":2}}"""))))
        skipMap(a)
        @test nextMap(a).districting == Districting(("B", "c") => 2)
        @test eof(a)
        @test_throws EOFError nextMap(a)
        md = parseMapData(mapLine("""{"A":{}}"""), Dict{String,Any})     # the assignment is not even scanned
        @test md.name == "x"
    end

    @testset "randomized: a v2 tree reads to the districting it encodes" begin
        rng = Xoshiro(20261123)
        chars = collect("aZ09 \"\\,[]{}:'/éñ中😀\t")
        rname() = String(rand(rng, chars, rand(rng, 0:6)))
        for _ in 1:200
            d = Districting()
            for _ in 1:rand(rng, 0:30)
                k = Tuple(rname() for _ in 1:rand(rng, 1:4))
                # Rule 1: keep the keys prefix-free (skip a key that is a prefix of, or extends, another).
                any(o -> o[1:min(end, length(k))] == k[1:min(end, length(o))], keys(d)) && continue
                d[k] = rand(rng, -5:500)
            end
            # Build the tree and write it with JSON.jl (sorted, as the spec asks).
            tree = Dict{String,Any}()
            for (k, v) in d
                node = tree
                for p in k[1:end-1]
                    node = get!(node, p, Dict{String,Any}())
                end
                node[k[end]] = v
            end
            line = """{"name":"r","weight":1,"data":{},"assignment":$(JSON.json(tree))}"""
            @test parseMap(line, Dict{String,Any}).districting == d
        end
    end
end
