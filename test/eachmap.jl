# eachMap / eachMapData / openAtlas(f, path): iterating over an atlas's maps. They must give exactly what the
# nextMap / nextMapData loops give (or `f` of it, with a function), whatever the batch size, number of tasks and
# thread count, raise an error at the map where it occurs (or leave the map out, with onerror = :skip), and close
# what they open. Run with several threads (CI sets JULIA_NUM_THREADS) to test parallel parsing.

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

"The values given by iterating `it` (passed through `g`), and the error it raised (or `nothing`)."
function valuesUntilError(it; g = identity)
    out = []
    try
        for x in it
            push!(out, g(x))
        end
        return out, nothing
    catch e
        return out, e
    end
end

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

    @testset "eachMap(f): f of each map, in order ($(basename(path)), batch $batch, ntasks $ntasks)" for
            path in (atlasFileName, atlasFileNameGz, v2), batch in (1, 3, 256), ntasks in (1, 2, 4)
        expected = loopMaps(path)
        got = collect(eachMap(m -> (m.name, length(m.districting)), path; batch, ntasks))
        @test got == [(m.name, length(m.districting)) for m in expected]
        @test got isa Vector{Tuple{String,Int}}                     # eltype inferred from f
        @test all(sameMap.(collect(eachMap(path; batch, ntasks)), expected))
        data = collect(eachMapData(d -> d.weight, path; batch, ntasks))
        @test data == [d.weight for d in loopMaps(path; data = true)]
    end

    @testset "eachMap(f): the patterns in the docstring" begin
        names = [m.name for m in loopMaps(atlasFileName)]
        it = eachMap(atlasFileName) do m                            # do-block
            uppercase(m.name)
        end
        @test collect(it) == uppercase.(names)
        fs = Any[m -> m.name, m -> m.weight, m -> length(m.districting)]
        vals = collect(eachMap(m -> map(g -> g(m), fs), atlasFileName))    # a list chosen at run time
        @test [v[1] for v in vals] == names && all(v -> length(v) == 3, vals)
        @test [a for (a, _) in eachMap(m -> (m.name, m.weight), atlasFileName)] == names
        @test eltype(eachMap(m -> rand() < 2 ? 1 : "x", atlasFileName)) == Any    # not concrete: Any
    end

    @testset "eachMap(f): uneven work, many maps, results in order (ntasks $ntasks)" for ntasks in (1, 3, 8)
        many = repeat(MAP_LINES, 40)
        path = atlasWithLines(many; ext = ".jsonl.gz")
        slow(m) = (rand() < 0.1 && sleep(0.002); m.name)
        @test collect(eachMap(slow, path; ntasks, batch = 32)) == [m.name for m in loopMaps(path)]
    end

    @testset "ntasks and onerror are checked; default batch follows ntasks" begin
        @test_throws ArgumentError eachMap(atlasFileName; ntasks = 0)
        @test_throws ArgumentError eachMap(identity, atlasFileName; onerror = :ignore)
        @test_throws ArgumentError eachMapData(atlasFileName; onerror = :warn)
        @test eachMap(atlasFileName; ntasks = 1).batch == 1
        @test eachMap(atlasFileName; ntasks = 2).batch == 256
    end

    @testset "an error from f is raised unchanged at its map, after an @error log (batch $batch)" for
            batch in (1, 3, 256)
        names = [m.name for m in loopMaps(atlasFileName)]
        k = 4
        f(m) = m.name == names[k] ? throw(DomainError(m.name, "bad map")) : m.name
        logs, (got, err) = Test.collect_test_logs() do
            valuesUntilError(eachMap(f, atlasFileName; batch))
        end
        @test got == names[1:k - 1]
        @test err isa DomainError && err.val == names[k]            # not wrapped
        @test length(logs) == 1 && logs[1].level == Base.CoreLogging.Error
        @test occursin("map $k (\"$(names[k])\")", logs[1].message)
        ex = logs[1].kwargs[:exception]
        @test ex isa Tuple && ex[1] === err && !isempty(ex[2])      # with the backtrace from inside f
        # a parse error is raised as before, with no log
        lines = copy(MAP_LINES)
        lines[2] = "{not json"
        logs, (got, err) = Test.collect_test_logs() do
            valuesUntilError(eachMap(m -> m.name, atlasWithLines(lines); batch))
        end
        @test got == names[1:1] && err isa AtlasFormatError && isempty(logs)
    end

    @testset "onerror = :skip leaves out maps that fail to parse or for which f raises" begin
        names = [m.name for m in loopMaps(atlasFileName)]
        lines = copy(MAP_LINES)
        lines[2] = "{not json"
        path = atlasWithLines(lines)
        f(m) = m.name == names[5] ? error("no") : m.name
        for batch in (1, 3, 256), ntasks in (1, 2)
            logs, got = Test.collect_test_logs() do
                collect(eachMap(f, path; batch, ntasks, onerror = :skip))
            end
            @test got == names[[1; 3:4; 6:end]]
            @test count(l -> l.level == Base.CoreLogging.Error, logs) == 2
            @test occursin("map 2 was left out", logs[1].message)
            @test occursin("map 5 (\"$(names[5])\") was left out", logs[2].message)
            @test logs[end].level == Base.CoreLogging.Warn && occursin("left out 2 maps", logs[end].message)
        end
        logs, got = Test.collect_test_logs() do                     # without f, and eachMapData
            (collect(eachMap(path; onerror = :skip)), collect(eachMapData(path; onerror = :skip)))
        end
        @test [m.name for m in got[1]] == [d.name for d in got[2]] == names[[1; 3:end]]
        @test count(l -> l.level == Base.CoreLogging.Warn, logs) == 2
        # max counts the maps read, including those left out
        @test Test.collect_test_logs(() -> collect(eachMap(f, path; max = 5, onerror = :skip)))[2] == names[[1, 3, 4]]
        # nothing fails: no logs
        logs, got = Test.collect_test_logs(() -> collect(eachMap(m -> m.name, atlasFileName; onerror = :skip)))
        @test got == names && isempty(logs)
    end

    @testset "onerror = :skip logs the first 10, then the count" begin
        many = repeat(MAP_LINES, 10)
        path = atlasWithLines(many)
        bad = Set(1:3:length(many))                                 # map numbers that fail
        nbad = length(bad)
        lines = [i in bad ? "{broken $i" : l for (i, l) in enumerate(many)]
        logs, got = Test.collect_test_logs() do
            collect(eachMapData(atlasWithLines(lines); onerror = :skip, batch = 7))
        end
        @test length(got) == length(many) - nbad
        errs = filter(l -> l.level == Base.CoreLogging.Error, logs)
        @test length(errs) == 10
        @test occursin("map 1 was left out", errs[1].message) && occursin("map 28 was left out", errs[10].message)
        @test logs[end].level == Base.CoreLogging.Warn
        @test occursin("left out $nbad maps", logs[end].message) && occursin("first 10", logs[end].message)
    end

    @testset "onerror = :skip still raises a failure reading the stream" begin
        many = repeat(MAP_LINES, 200)
        good = atlasWithLines(many; ext = ".jsonl.gz")
        bytes = read(good)
        cut = joinpath(mktempdir(), "cut.jsonl.gz")
        write(cut, bytes[1:(length(bytes) * 2 ÷ 3)])
        logs, (got, err) = Test.collect_test_logs() do
            valuesUntilError(eachMap(m -> m.name, cut; onerror = :skip, batch = 64))
        end
        @test 0 < length(got) < length(many)
        @test err isa AtlasFormatError || err isa EOFError
    end

    @testset "eachMap(f, atlas) in openAtlas(f, path): closed after a break" begin
        local io
        found = openAtlas(atlasFileNameGz) do atlas
            io = atlas.io
            for name in eachMap(m -> m.name, atlas; batch = 2)
                name == "map3" && return name
            end
        end
        @test found == "map3" && !isopen(io)
        it = eachMap(m -> m.name, atlasFileName)
        collect(it)
        @test !isopen(it.atlas.io)
    end
end
