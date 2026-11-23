# Writing format v2 (`formatVersion=2` on newAtlas/addMap/addMaps/mapBytes/mapJSON) and converting between
# versions (`convertAtlas`). Uses helpers from v1_fixtures.jl and v2_fixtures.jl.

const SPEC_LINES = [l for l in split(read(joinpath(V2DIR, "spec_examples.jsonl"), String), "\n")[4:end] if !isempty(l)]

using Random: shuffle

"Read a whole (possibly compressed) file as text."
fileText(path) = (io = smartOpen(path, "r"); t = read(io, String); close(io); t)

"Open the atlas held in `bytes` and read all its maps."
atlasFromBytes(bytes) = (a = openAtlas(IOBuffer(bytes)); m = Map[]; while !eof(a); push!(m, nextMap(a)); end; (a, m))

mapsOf(path) = readAllMaps(path)[2]

@testset verbose = true "v2 format (writing and converting)" begin

    @testset "the writer produces the spec's examples byte for byte" begin
        for line in SPEC_LINES
            m = parseMap(line, Dict{String,Any})
            # data here has at most one key, so its bytes are fixed
            @test mapJSON(m; formatVersion=2) == line
            @test String(mapBytes(m; formatVersion="2")) == line * "\n"
        end
    end

    @testset "v1 output is unchanged" begin
        _, maps = readAllMaps(joinpath(FIXDIR, "edge.jsonl"))
        for m in maps
            @test mapJSON(m) == mapJSON(m; formatVersion=1) == mapJSON(m; formatVersion="1")
            @test mapBytes(m) == mapBytes(m; formatVersion=1)
        end
        io1, io2 = IOBuffer(), IOBuffer()
        h = AtlasHeader("d", "t", "A", "M")
        newAtlas(io1, h, Dict{String,Any}("k" => 1))
        newAtlas(io2, h, Dict{String,Any}("k" => 1); formatVersion=1)
        @test take!(io1) == take!(io2)
    end

    @testset "v2 header" begin
        io = IOBuffer()
        newAtlas(io, AtlasHeader("d", "t", "A", "M"; weightType="Float64"), Dict{String,Any}("k" => 1); formatVersion=2)
        @test String(take!(io)) == BANNER * "\n" *
            "{\"description\":\"d\",\"date\":\"t\",\"atlasParamType\":\"A\",\"mapParamType\":\"M\"," *
            "\"weightType\":\"Float64\",\"formatVersion\":\"2\"}\n{\"k\":1}\n"
    end

    @testset "keys are sorted at every level, whatever the insertion order" begin
        pairs = [("b", "z") => 1, ("b", "a") => 2, ("a",) => 3, ("é",) => 4, ("Z",) => 5, ("b", "é", "x") => 6,
                 ("b", "é", "a") => 7, ("中",) => 8, ("😀",) => 9, ("",) => 10]
        line = mapJSON(Map{Dict{String,Any}}("m", Districting(pairs), 1, Dict{String,Any}()); formatVersion=2)
        @test endswith(line, "\"assignment\":{\"\":10,\"Z\":5,\"a\":3,\"b\":{\"a\":2,\"z\":1,\"é\":{\"a\":7,\"x\":6}}," *
                             "\"é\":4,\"中\":8,\"😀\":9}}")
        for _ in 1:5
            d = Districting(); for p in shuffle(pairs); d[p[1]] = p[2]; end
            @test mapJSON(Map{Dict{String,Any}}("m", d, 1, Dict{String,Any}()); formatVersion=2) == line
        end
    end

    @testset "the writer refuses what v2 cannot hold" begin
        mk(d) = Map{Dict{String,Any}}("bad map", d, 1, Dict{String,Any}())
        for d in [Districting(("A",) => 1, ("A", "b") => 2),                       # prefix (rule 1)
                  Districting(("A", "b") => 1, ("A", "b", "c") => 2, ("Z",) => 3),  # deeper prefix
                  Districting(() => 1)]                                             # empty key
            err = try mapJSON(mk(d); formatVersion=2); nothing catch e; e end
            @test err isa AtlasFormatError && occursin("map \"bad map\"", err.msg)
            @test_throws AtlasFormatError addMap(IOBuffer(), mk(d); formatVersion=2)
            @test_throws AtlasFormatError addMaps(IOBuffer(), [mk(Districting(("x",) => 1)), mk(d)]; formatVersion=2)
            @test mapJSON(mk(d)) isa String                                         # v1 can still write it
        end
        # Siblings that merely share a first character are fine.
        @test parseMap(mapJSON(mk(Districting(("A",) => 1, ("AB", "c") => 2)); formatVersion=2),
                       Dict{String,Any}).districting == Districting(("A",) => 1, ("AB", "c") => 2)
        for v in (3, "3", 0, 2.0, :two, nothing)
            @test_throws ArgumentError mapJSON(mk(Districting(("x",) => 1)); formatVersion=v)
            @test_throws ArgumentError newAtlas(IOBuffer(), AtlasHeader("d", "t", "A", "M"), Dict(); formatVersion=v)
        end
    end

    @testset "randomized: write v2, read back" begin
        rng = Xoshiro(20261124)
        chars = collect("aZ09 \"\\,[]{}:'/éñ中😀\t\n")
        rname() = String(rand(rng, chars, rand(rng, 0:6)))
        maps = Map{Dict{String,Any}}[]
        for i in 1:200
            d = Districting()
            for _ in 1:rand(rng, 0:30)
                k = Tuple(rname() for _ in 1:rand(rng, 1:4))
                any(o -> o[1:min(end, length(k))] == k[1:min(end, length(o))], keys(d)) && continue
                d[k] = rand(rng, -5:2000)
            end
            push!(maps, Map{Dict{String,Any}}(rname(), d, rand(rng, 1:9), Dict{String,Any}("i" => i, "x" => rand(rng))))
        end
        io = IOBuffer()
        newAtlas(io, AtlasHeader("fuzz", "t", "A", "M"), Dict{String,Any}(); formatVersion=2)
        addMaps(io, maps; formatVersion=2)
        bytes = take!(io)
        one = IOBuffer(); for m in maps; addMap(one, m; formatVersion=2); end
        @test bytes[findall(==(UInt8('\n')), bytes)[3]+1:end] == take!(one)     # addMaps == addMap, byte for byte
        a, back = atlasFromBytes(bytes)
        @test a.formatVersion == "2"
        @test [m.districting for m in back] == [m.districting for m in maps]
        @test [m.name for m in back] == [m.name for m in maps]
        @test all(typedEqual(b.data, plainval(m.data)) for (b, m) in zip(back, maps))
    end

    @testset "convertAtlas" begin
        dir = mktempdir()
        @testset "v1 -> v2 gives exactly the v2 twin: $f" for f in sort(collect(keys(EXPECTED["fixtures"])))
            out = joinpath(dir, "to2_" * f)
            @test convertAtlas(joinpath(FIXDIR, f), out; formatVersion=2) == length(EXPECTED["fixtures"][f]["maps"])
            @test fileText(out) == fileText(joinpath(V2DIR, f))
        end
        @testset "v2 -> v1 -> v2 is lossless: $f" for f in sort(collect(keys(EXPECTED["fixtures"])))
            v1 = joinpath(dir, "to1_" * f)
            again = joinpath(dir, "again2_" * f)
            convertAtlas(joinpath(V2DIR, f), v1; formatVersion=1)
            convertAtlas(v1, again; formatVersion=2)
            @test fileText(again) == fileText(joinpath(V2DIR, f))
            orig, conv = fileText(joinpath(FIXDIR, f)), fileText(v1)
            @test split(conv, "\n")[1:3] == split(orig, "\n")[1:3]                # banner, header, params: same bytes
            @test [m.districting for m in mapsOf(v1)] == [m.districting for m in mapsOf(joinpath(FIXDIR, f))]
            @test all(typedEqual(x.data, y.data) for (x, y) in zip(mapsOf(v1), mapsOf(joinpath(FIXDIR, f))))
        end
        @testset "NC atlas, both ways, across compressions" begin
            nc = joinpath(REPO_ROOT, EXPECTED["nc_truncated"]["path"])
            v2gz = joinpath(dir, "nc.jsonl.gz"); v1bz = joinpath(dir, "nc.jsonl.bz2")
            @test convertAtlas(nc, v2gz; formatVersion=2) == 20
            # The NC file has no final newline; convertAtlas ends every line, the last included, with one.
            @test fileText(v2gz) == fileText(joinpath(V2DIR, "nc_truncated.jsonl.gz")) * "\n"
            @test convertAtlas(v2gz, v1bz; formatVersion=1, batch=3) == 20
            @test [m.districting for m in mapsOf(v1bz)] == [m.districting for m in mapsOf(nc)]
        end
        @testset "same version: a plain copy" begin
            out = joinpath(dir, "same.jsonl")
            convertAtlas(joinpath(V2DIR, "spec_examples.jsonl"), out; formatVersion=2)
            @test read(out) == read(joinpath(V2DIR, "spec_examples.jsonl"))
        end
        @testset "errors name the line and map, and remove dst" begin
            hdr1 = "\"banner\"\n" * V1_HEADER * "\n{}\n"
            write(joinpath(dir, "prefix.jsonl"), hdr1 *
                  """{"name":"ok","weight":1,"data":{},"districting":[{"[\\"A\\"]":1}]}\n""" *
                  """{"name":"both","weight":1,"data":{},"districting":[{"[\\"A\\"]":1},{"[\\"A\\", \\"b\\"]":2}]}\n""")
            out = joinpath(dir, "prefix_out.jsonl")
            err = try convertAtlas(joinpath(dir, "prefix.jsonl"), out; formatVersion=2); nothing catch e; e end
            @test err isa AtlasFormatError && occursin("line 5", err.msg) && occursin("map \"both\"", err.msg) &&
                  occursin("prefix", err.msg)
            @test !isfile(out)
            # A v2 line in a v1 file.
            write(joinpath(dir, "mixed.jsonl"), hdr1 * """{"name":"x","weight":1,"data":{},"assignment":{"A":1}}\n""")
            err = try convertAtlas(joinpath(dir, "mixed.jsonl"), out; formatVersion=2); nothing catch e; e end
            @test err isa AtlasFormatError && occursin("line 4", err.msg) && occursin("has no \"districting\"", err.msg)
            # The assignment must be the last field (convertAtlas only rewrites that field).
            write(joinpath(dir, "order.jsonl"), hdr1 * """{"name":"x","districting":[],"weight":1,"data":{}}\n""")
            err = try convertAtlas(joinpath(dir, "order.jsonl"), out; formatVersion=2); nothing catch e; e end
            @test err isa AtlasFormatError && occursin("last field", err.msg)
            @test_throws ArgumentError convertAtlas(out, out; formatVersion=2)
            @test_throws ArgumentError convertAtlas(joinpath(dir, "missing.jsonl"), out; formatVersion=2)
            @test_throws ArgumentError convertAtlas(joinpath(dir, "prefix.jsonl"), out; formatVersion=3)
        end
        @testset "_lastTopLevelKeyStart skips nested keys and strings" begin
            for (s, key) in [("""{"a":1,"b":{"c":2}}""", "\"b\""),
                             ("""{"a":"x\\",\\"y\\":1","z":[{"q":1}]}""", "\"z\""),
                             ("""{ "a" : 1 , "last" : {} }""", "\"last\""),
                             ("""{"only":[1,2,{"k":"v"}]}""", "\"only\"")]
                i = AtlasIO._lastTopLevelKeyStart(s)
                @test s[i:i+length(key)-1] == key
            end
        end
    end
end
