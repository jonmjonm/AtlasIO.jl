# eachMap / eachMapData / openAtlas(f, path): iterating over an atlas's maps. They must give exactly what the
# nextMap / nextMapData loops give, whatever the batch size and thread count, raise an error at the map where it
# occurs, and close what they open. Run with several threads (CI sets JULIA_NUM_THREADS) to test parallel parsing.

"Every map of `path`, by the `nextMap` (or `nextMapData`) loop."
function loopMaps(path; data = false)
    atlas = openAtlas(smartOpen(path, "r"))
    out = []
    while !eof(atlas)
        push!(out, data ? nextMapData(atlas) : nextMap(atlas))
    end
    close(atlas)
    return out
end

sameMap(a::Map, b::Map) = a.name == b.name && a.districting == b.districting && a.weight == b.weight && a.data == b.data
sameMap(a::MapData, b::MapData) = a.name == b.name && a.weight == b.weight && a.data == b.data

"An atlas file in a fresh directory: `test.jsonl`'s header, then `lines` as its map lines."
function atlasWithLines(lines; ext = ".jsonl")
    src = readlines(atlasFileName)
    path = joinpath(mktempdir(), "a" * ext)
    io = smartOpen(path, "w")
    foreach(l -> println(io, l), src[1:3])
    foreach(l -> println(io, l), lines)
    close(io)
    return path
end
const MAP_LINES = readlines(atlasFileName)[4:end]

"The names given by iterating `it`, and the error it raised (or `nothing`)."
function namesUntilError(it)
    names = String[]
    try
        for m in it
            push!(names, m.name)
        end
        return names, nothing
    catch e
        return names, e
    end
end

@testset verbose = true "eachMap / eachMapData" begin
    v2 = joinpath(mktempdir(), "test_v2.jsonl.gz")
    convertAtlas(atlasFileName, v2; formatVersion = 2)

    @testset "the same maps as the nextMap loop ($(basename(path)), batch $batch)" for
            path in (atlasFileName, atlasFileNameGz, v2), batch in (1, 2, 3, 5, 256)
        expected = loopMaps(path)
        got = collect(eachMap(path; batch = batch))
        @test length(got) == length(expected) == length(MAP_LINES)
        @test all(sameMap.(got, expected))
        @test got isa Vector{Map{Dict{String,Any},Int64}}           # eltype is concrete
        data = collect(eachMapData(path; batch = batch))
        @test all(sameMap.(data, loopMaps(path; data = true)))
        @test data isa Vector{MapData{Dict{String,Any},Int64}}
    end

    @testset "skip and max" begin
        names = [m.name for m in loopMaps(atlasFileName)]
        for batch in (1, 4), skip in (0, 1, 5, length(names), length(names) + 3), max in (0, 1, 3, 100)
            @test [m.name for m in eachMap(atlasFileName; skip, max, batch)] ==
                  names[min(skip, length(names)) + 1:min(skip + max, length(names))]
        end
        @test [d.name for d in eachMapData(atlasFileName; skip = 2, max = 2)] == names[3:4]
        @test_throws ArgumentError eachMap(atlasFileName; skip = -1)
        @test_throws ArgumentError eachMap(atlasFileName; max = -1)
        @test_throws ArgumentError eachMap(atlasFileName; batch = 0)
    end

    @testset "an atlas given: read from where it is, never closed" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        first = nextMap(atlas)
        rest = collect(eachMap(atlas; batch = 3))
        @test [first.name; [m.name for m in rest]] == [m.name for m in loopMaps(atlasFileName)]
        @test isopen(io)                                            # the caller closes it
        @test isempty(collect(eachMap(atlas)))                      # nothing left
        close(atlas)
    end

    @testset "a path: closed when the last map is read, or on an error" begin
        it = eachMap(atlasFileNameGz; batch = 4)
        for _ in it end
        @test !isopen(it.atlas.io)
        @test iterate(it) === nothing                               # stays finished
        it = eachMap(atlasFileName; max = 2)
        @test length(collect(it)) == 2 && !isopen(it.atlas.io)
        bad = atlasWithLines([MAP_LINES[1], "{not json"])
        it = eachMap(bad)
        @test_throws AtlasFormatError collect(it)
        @test !isopen(it.atlas.io)
        @test_throws SystemError eachMap(joinpath(mktempdir(), "missing.jsonl"))     # nothing to open
    end

    @testset "an error is raised at its map, after the maps before it ($what, batch $batch)" for
            (what, k) in (("first", 1), ("middle", 4), ("last", length(MAP_LINES))), batch in (1, 3, 256)
        lines = copy(MAP_LINES)
        lines[k] = "{\"name\": broken"                                         # not JSON
        names, err = namesUntilError(eachMap(atlasWithLines(lines); batch))
        @test names == [m.name for m in loopMaps(atlasFileName)][1:k - 1]
        @test err isa AtlasFormatError
        names, err = namesUntilError(eachMapData(atlasWithLines(lines); batch))
        @test length(names) == k - 1 && err isa AtlasFormatError
    end

    @testset "a corrupt compressed file: the maps before the damage, then the error" begin
        many = repeat(MAP_LINES, 200)
        good = atlasWithLines(many; ext = ".jsonl.gz")
        bytes = read(good)
        cut = joinpath(mktempdir(), "cut.jsonl.gz")
        write(cut, bytes[1:(length(bytes) * 2 ÷ 3)])               # truncated two thirds of the way
        for batch in (1, 64)
            names, err = namesUntilError(eachMap(cut; batch))
            @test 0 < length(names) < length(many)
            @test names == [m.name for m in loopMaps(good)][1:length(names)]
            @test err isa AtlasFormatError || err isa EOFError
        end
    end

    @testset "openAtlas(f, path): closed after a break, a return or an error" begin
        local io
        found = openAtlas(atlasFileNameGz) do atlas
            io = atlas.io
            for m in eachMap(atlas; batch = 2)
                m.name == "map3" && return m.name
            end
        end
        @test found == "map3" && !isopen(io)
        @test_throws ErrorException openAtlas(atlasFileName) do atlas
            io = atlas.io
            for m in eachMap(atlas)
                error("stop")
            end
        end
        @test !isopen(io)
        @test openAtlas(a -> length(collect(eachMapData(a))), atlasFileName) == length(MAP_LINES)
    end
end
