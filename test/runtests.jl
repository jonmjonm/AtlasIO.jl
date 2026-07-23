using Test
using AtlasIO
using JSON3                        # for comparing parseMapData against a direct Map parse
using CodecZlib: GzipDecompressor   # for verifying the parallel-gzip writer's output
using Sockets
using Downloads
using TranscodingStreams

"""
Minimal single-shot HTTP server for exercising `smartOpen` over `http://`.
Serves `body` bytes for any request whose path is in `okPaths`, else 404.
Runs `n` requests total then stops listening.
"""
function withHTTPServer(f, filesByPath::Dict{String,Vector{UInt8}}; n=1)
    server = listen(Sockets.localhost, 0)
    _, port = getsockname(server)
    task = @async begin
        for _ in 1:n
            sock = accept(server)
            try
                request = String(readuntil(sock, "\r\n\r\n"))
                path = split(split(request, ' ')[2], '?')[1]
                if haskey(filesByPath, path)
                    body = filesByPath[path]
                    write(sock, "HTTP/1.1 200 OK\r\nContent-Length: $(length(body))\r\nConnection: close\r\n\r\n")
                    write(sock, body)
                else
                    write(sock, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                end
            finally
                close(sock)
            end
        end
    end
    try
        f("http://127.0.0.1:$(Int(port))")
    finally
        close(server)
        wait(task)
    end
end

const atlasFileName   = joinpath(@__DIR__, "test.jsonl")
const atlasFileNameGz = joinpath(@__DIR__, "test.jsonl.gz")

const TOTAL_MAPS = 14

const first_map_truth = Dict{Tuple{Vararg{String}}, Int64}(
    ("p2", "c2") => 1, ("p1", "c2") => 1, ("p3", "c7", "b100") => 2)
const second_map_truth = Dict{Tuple{Vararg{String}}, Int64}(
    ("p2", "c2") => 2, ("p1", "c2") => 1, ("p3", "c7", "b100") => 1)

@testset verbose=true "Atlas Tests" begin
    @testset "Uncompressed Reading" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        @test !eof(atlas)
        @test atlas.description == "Test Atlas"
        @test atlas.date == "2021-08-04T08:58:22.216"
        @test atlas.atlasParam["county"] == 2
        @test atlas.atlasParam["gamama"] == 4

        m1 = nextMap(atlas)
        @test m1.name == "map1"
        @test m1.weight == 1
        @test length(m1.districting) == 3
        @test m1.districting == first_map_truth

        m2 = nextMap(atlas)
        @test m2.name == "map2"
        @test m2.districting == second_map_truth

        close(io)
    end

    @testset "Gzip Reading" begin
        io = smartOpen(atlasFileNameGz, "r")
        atlas = openAtlas(io)
        @test !eof(atlas)
        @test atlas.description == "Test Atlas"
        @test atlas.atlasParam["county"] == 2

        m1 = nextMap(atlas)
        @test m1.name == "map1"
        @test m1.districting == first_map_truth

        m2 = nextMap(atlas)
        @test m2.name == "map2"
        @test m2.districting == second_map_truth

        close(io)
    end

    @testset "EOF Detection" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        count = 0
        while !eof(atlas)
            nextMap(atlas)
            count += 1
        end
        @test count == TOTAL_MAPS
        @test eof(atlas)
        close(io)
    end

    @testset "Weight Field" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        m1 = nextMap(atlas)
        @test m1.weight == 1
        nextMap(atlas)  # map2
        nextMap(atlas)  # map3
        m10 = nextMap(atlas)  # map-10
        @test m10.name == "map-10"
        @test m10.weight == 10
        close(io)
    end

    @testset "skipMap" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        m1 = nextMap(atlas)
        @test m1.name == "map1"
        skipMap(atlas)          # skips map2
        m3 = nextMap(atlas)
        @test m3.name == "map3"
        close(io)
    end

    @testset "parseBufferToMap" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        raw_line = readline(atlas.io)  # first map line, position is after the 3-line header
        m = parseBufferToMap(atlas, raw_line)
        @test m.name == "map1"
        @test m.districting == first_map_truth
        close(io)
    end

    @testset "MapData/nextMapData/parseBufferToMapData: name/weight/data match Map's, no districting" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)

        m1 = nextMap(atlas)                 # ground truth, from the real Map parse
        md1 = nextMapData(atlas)            # map2, parsed via the fast path
        @test md1 isa MapData
        @test !hasfield(MapData, :districting)
        @test md1.name == "map2"
        @test md1.weight == 1
        @test md1.data == Dict{String,Int64}("param" => 2, "trees" => 4)
        close(io)

        io2 = smartOpen(atlasFileName, "r")
        atlas2 = openAtlas(io2)
        raw_line = readline(atlas2.io)      # map1's raw line
        md = parseBufferToMapData(atlas2, raw_line)
        @test md.name == m1.name
        @test md.weight == m1.weight
        @test md.data == m1.data
        close(io2)

        io3 = smartOpen(atlasFileName, "r")
        atlas3 = openAtlas(io3)
        mdRaw = parseMapData(readline(atlas3.io), atlas3.mapParamType, atlas3.weightType)
        @test mdRaw.name == "map1"
        @test mdRaw.data == m1.data
        close(io3)
    end

    @testset "parseMapData matches Map's parse for a non-Dict, non-object data/T (Map places no such constraint)" begin
        line = """{"name":"m1","weight":1,"data":42,"districting":[{"[\\"a\\"]":1}]}"""
        m = JSON3.read(line, Map{Int64,Int64})
        md = parseMapData(line, Int64, Int64)
        @test md.name == m.name == "m1"
        @test md.weight == m.weight == 1
        @test md.data == m.data == 42
    end

    @testset "nextMapData raises EOFError/AtlasFormatError like nextMap" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        while !eof(atlas); nextMapData(atlas); end
        @test_throws EOFError nextMapData(atlas)
        close(io)

        io2 = smartOpen(atlasFileName, "r")
        atlas2 = openAtlas(io2)
        @test_throws AtlasFormatError parseBufferToMapData(atlas2, "not json")
        close(io2)
    end

    @testset "Write/Read Round-trip" begin
        header = AtlasHeader("RT Atlas", "2024-01-01T00:00:00", "Dict{String,Any}", "Dict{String,Any}")
        params = Dict{String,Any}("n" => 2)
        dist_a = Districting(("r1",) => 1, ("r2",) => 2)
        dist_b = Districting(("r1",) => 2, ("r2",) => 1)

        for (suffix, label) in [(".jsonl", "uncompressed"), (".jsonl.gz", "gzip"), (".jsonl.bz2", "bzip2")]
            @testset "$label" begin
                tmpfile = tempname() * suffix

                io_w = smartOpen(tmpfile, "w")
                newAtlas(io_w, header, params)
                addMap(io_w, Map{Dict{String,Any}}(name="alpha", districting=dist_a, weight=1, data=Dict{String,Any}()))
                addMap(io_w, Map{Dict{String,Any}}(name="beta",  districting=dist_b, weight=7, data=Dict{String,Any}()))
                close(io_w)

                io_r = smartOpen(tmpfile, "r")
                atlas = openAtlas(io_r)
                @test atlas.description == "RT Atlas"
                @test atlas.atlasParam["n"] == 2

                ma = nextMap(atlas)
                @test ma.name == "alpha"
                @test ma.weight == 1
                @test ma.districting == dist_a

                mb = nextMap(atlas)
                @test mb.name == "beta"
                @test mb.weight == 7
                @test mb.districting == dist_b

                @test eof(atlas)
                close(io_r)
                rm(tmpfile)
            end
        end
    end

    @testset "copyAtlasHeader" begin
        tmpfile = tempname() * ".jsonl"
        copyAtlasHeader(atlasFileName, tmpfile)
        io = smartOpen(tmpfile, "r")
        atlas = openAtlas(io)
        @test atlas.description == "Test Atlas"
        @test atlas.date == "2021-08-04T08:58:22.216"
        @test eof(atlas)   # header only — no map lines
        close(io)
        rm(tmpfile)
    end

    @testset "copyAtlasHeader compressed" begin
        for (src, dst) in [(atlasFileNameGz, tempname()*".jsonl"),
                           (atlasFileName,   tempname()*".jsonl.gz"),
                           (atlasFileName,   tempname()*".jsonl.bz2")]
            copyAtlasHeader(src, dst)
            io = smartOpen(dst, "r")
            atlas = openAtlas(io)
            @test atlas.description == "Test Atlas"
            @test eof(atlas)
            close(io)
            rm(dst)
        end
    end

    @testset "skipMap numSkip>1" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        skipMap(atlas; numSkip=2)   # skips map1 and map2
        m3 = nextMap(atlas)
        @test m3.name == "map3"
        close(io)
    end

    @testset "addMap low-level overload" begin
        tmpfile = tempname() * ".jsonl"
        header = AtlasHeader("LLW Atlas", "2024-06-01T00:00:00", "Dict{String,Any}", "Dict{String,Any}")
        params = Dict{String,Any}("n" => 1)
        dist   = Districting(("r1",) => 1, ("r2",) => 2)
        data   = Dict{String,Any}("votes" => 99)

        io_w = smartOpen(tmpfile, "w")
        newAtlas(io_w, header, params)
        addMap(io_w, dist, "mymap", Int64(3), data)
        close(io_w)

        io_r = smartOpen(tmpfile, "r")
        atlas = openAtlas(io_r)
        m = nextMap(atlas)
        @test m.name == "mymap"
        @test m.weight == 3
        @test m.districting == dist
        @test eof(atlas)
        close(io_r)
        rm(tmpfile)
    end

    @testset "smartOpen fallback extension" begin
        # request .jsonl.gz that doesn't exist — falls back to .jsonl
        plain = tempname() * ".jsonl"
        cp(atlasFileName, plain)
        io = smartOpen(plain * ".gz", "r")
        @test io !== nothing
        atlas = openAtlas(io)
        @test atlas.description == "Test Atlas"
        close(io)
        rm(plain)

        # request .jsonl that doesn't exist — falls back to .jsonl.gz
        gz = tempname() * ".jsonl.gz"
        cp(atlasFileNameGz, gz)
        io2 = smartOpen(replace(gz, ".gz" => ""), "r")
        @test io2 !== nothing
        atlas2 = openAtlas(io2)
        @test atlas2.description == "Test Atlas"
        close(io2)
        rm(gz)
    end

    @testset "smartOpen over http(s) URLs" begin
        gzBytes    = read(atlasFileNameGz)
        plainBytes = read(atlasFileName)

        @testset "buffered (default): streams via Base.BufferStream" begin
            # a HEAD existence-check precedes the streamed GET, so n=2
            withHTTPServer(Dict("/test.jsonl.gz" => gzBytes); n=2) do base
                io = smartOpen(base * "/test.jsonl.gz", "r")
                @test io isa TranscodingStreams.TranscodingStream
                @test io.stream isa AtlasIO.URLStream
                atlas = openAtlas(io)
                @test atlas.description == "Test Atlas"
                @test length(nextMaps(atlas)) == TOTAL_MAPS
                close(io)
            end

            withHTTPServer(Dict("/test.jsonl" => plainBytes); n=2) do base
                io = smartOpen(base * "/test.jsonl", "r")
                @test io isa AtlasIO.URLStream
                atlas = openAtlas(io)
                @test atlas.description == "Test Atlas"
                close(io)
            end

            # request .bz2 that doesn't exist -- HEAD 404s, HEAD on the
            # uncompressed fallback succeeds, then that URL is streamed (n=3)
            withHTTPServer(Dict("/test.jsonl" => plainBytes); n=3) do base
                io = smartOpen(base * "/test.jsonl.bz2", "r")
                atlas = openAtlas(io)
                @test atlas.description == "Test Atlas"
                close(io)
            end

            # a genuine 404 (no fallback candidate matches either) propagates as
            # an error -- both HEAD checks 404, no GET is ever attempted (n=2)
            withHTTPServer(Dict{String,Vector{UInt8}}(); n=2) do base
                @test_throws Downloads.RequestError smartOpen(base * "/missing.jsonl", "r")
            end
        end

        @testset "_isMissingResponse handles a connection-level failure (RequestError), not just a Response" begin
            # Downloads.request(...; throw=false) can *return* (not throw) a
            # RequestError when the failure never reached HTTP semantics -- e.g.
            # the connection itself was refused/aborted -- so there's no .status
            # to check. _isMissingResponse must treat that as "not confirmed
            # missing" rather than crash trying to read resp.status off it.
            dummyResp = Downloads.Response(nothing, "http://x", 200, "", Pair{String,String}[])
            connErr = Downloads.RequestError("http://x", 7, "Couldn't connect", dummyResp)
            @test AtlasIO._isMissingResponse(connErr) == false
            @test AtlasIO._isMissingResponse(nothing) == false
            @test AtlasIO._isMissingResponse(
                Downloads.Response(nothing, "http://x", 404, "", Pair{String,String}[])) == true
            @test AtlasIO._isMissingResponse(
                Downloads.Response(nothing, "http://x", 200, "", Pair{String,String}[])) == false

            # End-to-end: nothing is listening on this port at all, so the HEAD
            # request fails below the HTTP level. Must not crash inside
            # _isMissingResponse; propagates as a real connection error from the
            # subsequent GET instead.
            deadServer = listen(Sockets.localhost, 0)
            _, deadPort = getsockname(deadServer)
            close(deadServer)   # nothing listens here now
            @test_throws Downloads.RequestError smartOpen(
                "http://127.0.0.1:$(Int(deadPort))/dead.jsonl", "r")
        end

        @testset "download=true: fetches to a temp file first" begin
            withHTTPServer(Dict("/test.jsonl.gz" => gzBytes)) do base
                io = smartOpen(base * "/test.jsonl.gz", "r"; download=true)
                @test io isa TranscodingStreams.TranscodingStream
                @test io.stream isa IOStream
                atlas = openAtlas(io)
                @test atlas.description == "Test Atlas"
                @test length(nextMaps(atlas)) == TOTAL_MAPS
                close(io)
            end

            # request .bz2 that doesn't exist (404) -- falls back to the
            # uncompressed name (n=2: the failed GET, then the successful one)
            withHTTPServer(Dict("/test.jsonl" => plainBytes); n=2) do base
                io = smartOpen(base * "/test.jsonl.bz2", "r"; download=true)
                atlas = openAtlas(io)
                @test atlas.description == "Test Atlas"
                close(io)
            end

            # a genuine 404 (no fallback candidate matches) propagates as an error
            withHTTPServer(Dict{String,Vector{UInt8}}(); n=2) do base
                @test_throws Downloads.RequestError smartOpen(base * "/missing.jsonl", "r"; download=true)
            end
        end

        # writing to a URL is not supported, regardless of download/buffered mode
        withHTTPServer(Dict{String,Vector{UInt8}}(); n=0) do base
            @test_throws ArgumentError smartOpen(base * "/out.jsonl", "w")
            @test_throws ArgumentError smartOpen(base * "/out.jsonl", "w"; download=true)
        end
    end

    @testset "AtlasHeader DataType constructors" begin
        h1 = AtlasHeader("A", "2024-01-01T00:00:00", Dict{String,Any}, Dict{String,Any})
        @test h1.description == "A"
        @test h1.atlasParamType == "Dict{String, Any}"
        @test h1.mapParamType  == "Dict{String, Any}"

        h2 = AtlasHeader("B", Dict{String,Any}, Dict{String,Any})
        @test h2.description == "B"
        @test h2.atlasParamType == "Dict{String, Any}"
        @test !isempty(h2.date)   # auto-filled with now()
    end

    @testset "nextMap with EachLine iterator" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        iter = eachline(atlas.io)
        m1 = nextMap(atlas, iter)
        @test m1.name == "map1"
        @test m1.districting == first_map_truth
        m2 = nextMap(atlas, iter)
        @test m2.name == "map2"
        close(io)
    end

    @testset "close(atlas)" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        nextMap(atlas)
        close(atlas)   # Atlas overload, not close(io)
        @test isopen(io) == false
    end

    @testset "Map data field" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        m1 = nextMap(atlas)
        @test m1.data["param"] == 2
        @test m1.data["trees"] == 4
        close(io)
    end

    @testset "Round-trip with non-empty data" begin
        tmpfile = tempname() * ".jsonl"
        header = AtlasHeader("Data Atlas", "2024-01-01T00:00:00", "Dict{String,Any}", "Dict{String,Any}")
        params = Dict{String,Any}()
        dist   = Districting(("x",) => 1)
        data   = Dict{String,Any}("score" => 3.14, "label" => "test")

        io_w = smartOpen(tmpfile, "w")
        newAtlas(io_w, header, params)
        addMap(io_w, Map{Dict{String,Any}}(name="d1", districting=dist, weight=1, data=data))
        close(io_w)

        io_r = smartOpen(tmpfile, "r")
        atlas = openAtlas(io_r)
        m = nextMap(atlas)
        @test m.data["score"]  == 3.14
        @test m.data["label"]  == "test"
        close(io_r)
        rm(tmpfile)
    end

    @testset "Byte-identical serialization" begin
        m = Map{Dict{String,Any}}(name="m1", districting=Districting(("DAVIDSON", "12,14") => 2),
                                   weight=3, data=Dict{String,Any}())
        expected = "{\"name\":\"m1\",\"weight\":3,\"data\":{},\"districting\":[{\"[\\\"DAVIDSON\\\", \\\"12,14\\\"]\":2}]}"

        io = IOBuffer()
        addMap(io, m)
        @test String(take!(io)) == expected * "\n"
    end

    @testset "nextMaps parity" begin
        for (file, label) in [(atlasFileName, "uncompressed"), (atlasFileNameGz, "gzip")]
            @testset "$label" begin
                # serial reference
                io = smartOpen(file, "r"); atlas = openAtlas(io)
                serial = AtlasIO.Map[]
                while !eof(atlas); push!(serial, nextMap(atlas)); end
                close(io)

                # parallel, small batch to force multiple chunks over 14 maps
                io2 = smartOpen(file, "r"); atlas2 = openAtlas(io2)
                par = nextMaps(atlas2; batch=4)
                @test eof(atlas2)
                close(io2)

                @test length(par) == TOTAL_MAPS
                @test [m.name for m in par] == [m.name for m in serial]
                @test [m.districting for m in par] == [m.districting for m in serial]
                @test [m.weight for m in par] == [m.weight for m in serial]
            end
        end

        # `n` bound and composition with skipMap
        io = smartOpen(atlasFileName, "r"); atlas = openAtlas(io)
        skipMap(atlas)                       # drop map1
        par = nextMaps(atlas; n=2, batch=1)
        @test length(par) == 2
        @test par[1].name == "map2"
        @test !eof(atlas)                    # n bound stopped before EOF
        close(io)
    end

    @testset "addMaps parity with addMap" begin
        maps = [
            Map{Dict{String,Any}}(name="a", districting=Districting(("r1",)=>1), weight=1, data=Dict{String,Any}()),
            Map{Dict{String,Any}}(name="b", districting=Districting(("DAVIDSON","12,14")=>2), weight=7, data=Dict{String,Any}("v"=>3)),
            Map{Dict{String,Any}}(name="c", districting=Districting(("x",)=>1,("y",)=>2), weight=2, data=Dict{String,Any}()),
        ]
        io_serial = IOBuffer()
        for m in maps; addMap(io_serial, m); end
        expected = take!(io_serial)

        io_batch = IOBuffer()
        nb = addMaps(io_batch, maps)
        got = take!(io_batch)

        @test got == expected            # byte-identical
        @test nb == length(got)

        # round-trips through a real file
        tmpfile = tempname() * ".jsonl"
        header = AtlasHeader("Batch Atlas", "2024-01-01T00:00:00", "Dict{String,Any}", "Dict{String,Any}")
        io_w = smartOpen(tmpfile, "w")
        newAtlas(io_w, header, Dict{String,Any}())
        addMaps(io_w, maps)
        close(io_w)
        io_r = smartOpen(tmpfile, "r"); atlas = openAtlas(io_r)
        back = nextMaps(atlas)
        @test [m.name for m in back] == ["a", "b", "c"]
        @test back[2].districting == Districting(("DAVIDSON","12,14")=>2)
        close(io_r); rm(tmpfile)
    end

    @testset "Districting key with comma" begin
        tmpfile = tempname() * ".jsonl"
        header = AtlasHeader("Comma Atlas", "2024-01-01T00:00:00", "Dict{String,Any}", "Dict{String,Any}")
        params = Dict{String,Any}()
        dist   = Districting(("DAVIDSON", "12,14") => 11, ("GASTON",) => 14)

        io_w = smartOpen(tmpfile, "w")
        newAtlas(io_w, header, params)
        addMap(io_w, Map{Dict{String,Any}}(name="c1", districting=dist, weight=1, data=Dict{String,Any}()))
        close(io_w)

        io_r = smartOpen(tmpfile, "r")
        atlas = openAtlas(io_r)
        m = nextMap(atlas)
        @test m.name == "c1"
        @test m.districting == dist
        @test m.districting[("DAVIDSON", "12,14")] == 11
        @test eof(atlas)
        close(io_r)
        rm(tmpfile)
    end

    @testset "Float weights round-trip" begin
        tmpfile = tempname() * ".jsonl"
        header = AtlasHeader("Float Atlas", "2024-01-01T00:00:00",
                             Dict{String,Any}, Dict{String,Any}; weightType=Float64)
        @test header.weightType == "Float64"
        params = Dict{String,Any}()
        dist   = Districting(("r1",) => 1, ("r2",) => 2)

        io_w = smartOpen(tmpfile, "w")
        newAtlas(io_w, header, params)
        addMap(io_w, Map{Dict{String,Any}}(name="f1", districting=dist, weight=2.5, data=Dict{String,Any}()))
        addMap(io_w, dist, "f2", 3.75, Dict{String,Any}())   # low-level overload now accepts Real
        close(io_w)

        io_r = smartOpen(tmpfile, "r")
        atlas = openAtlas(io_r)
        @test atlas.weightType == Float64        # weightType survives write→read
        m1 = nextMap(atlas)
        @test m1.name == "f1"
        @test m1.weight == 2.5
        @test m1.weight isa Float64
        m2 = nextMap(atlas)
        @test m2.name == "f2"
        @test m2.weight == 3.75
        @test m2.weight isa Float64
        @test eof(atlas)
        close(io_r)
        rm(tmpfile)
    end

    @testset "weightType back-compat default" begin
        # test.jsonl header has no weightType; it must default to Int64.
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        @test atlas.weightType == Int64
        m1 = nextMap(atlas)
        @test m1.weight == 1
        @test m1.weight isa Int64
        close(io)
    end

    @testset "AtlasHeader weightType constructor" begin
        h = AtlasHeader("F", "2024-01-01T00:00:00",
                        Dict{String,Any}, Dict{String,Any}; weightType=Float64)
        @test h.weightType == "Float64"
        hdef = AtlasHeader("G", "2024-01-01T00:00:00", Dict{String,Any}, Dict{String,Any})
        @test hdef.weightType == "Int64"          # default when unspecified
    end

    @testset "parallel byte-targeted gzip output" begin
        @testset "isGzipOutput" begin
            @test isGzipOutput("a.jsonl.gz")
            @test !isGzipOutput("a.jsonl")
            @test !isGzipOutput("a.jsonl.bz2")   # falls back to the serial stream
        end

        @testset "groupByBytes" begin
            @test groupByBytes([4, 4, 4, 4], 8) == [1:2, 3:4]     # exact fit
            @test groupByBytes([3, 3, 3, 3, 3], 8) == [1:3, 4:5]  # closes at >= target
            @test groupByBytes([100, 1, 1], 8) == [1:1, 2:3]      # oversized record alone
            @test groupByBytes([1, 1, 1], 100) == [1:3]           # target > everything
            @test groupByBytes(Int[], 8) == UnitRange{Int}[]
            for sizes in ([5, 1, 9, 2, 7, 3], fill(1, 37))        # covers every index once, in order
                @test reduce(vcat, collect.(groupByBytes(sizes, 8))) == collect(1:length(sizes))
            end
        end

        @testset "gzipMember round-trip + concatenation" begin
            a = Vector{UInt8}("hello world\n" ^ 100)
            b = Vector{UInt8}("second chunk\n" ^ 100)
            @test transcode(GzipDecompressor, gzipMember(a)) == a
            @test transcode(GzipDecompressor, vcat(gzipMember(a), gzipMember(b))) == vcat(a, b)
        end

        @testset "writeGzipMembers! -> valid multi-member gzip, in order" begin
            recs = [Vector{UInt8}("record $i line\n") for i in 1:50]
            io = IOBuffer()
            writeGzipMembers!(io, recs, 4; target = 8)   # tiny target -> many members
            gz = take!(io)
            @test transcode(GzipDecompressor, gz) == reduce(vcat, recs)     # order preserved
            @test count(i -> gz[i] == 0x1f && gz[i+1] == 0x8b, 1:(length(gz)-1)) >= 2
        end

        @testset "AtlasOutput: .gz round-trips, plain is raw" begin
            dir = mktempdir()
            hdr = Vector{UInt8}("line1\nline2\nline3\n")
            recs = [Vector{UInt8}("map $i data\n") for i in 1:20]
            content = vcat(hdr, reduce(vcat, recs))

            pgz = joinpath(dir, "t.jsonl.gz")           # gzip path -> parallel members
            out = openAtlasOutput(pgz, hdr, 4)
            writeMaps!(out, recs); close(out)
            @test success(`gzip -t $pgz`)
            @test transcode(GzipDecompressor, read(pgz)) == content
            @test count(let b = read(pgz); i -> b[i] == 0x1f && b[i+1] == 0x8b end,
                        1:(filesize(pgz)-1)) >= 2

            pplain = joinpath(dir, "t.jsonl")           # plain path -> written raw
            out = openAtlasOutput(pplain, hdr, 4)
            writeMaps!(out, recs); close(out)
            @test read(pplain) == content

            # header round-trips through atlasHeaderBytes on both encodings
            @test atlasHeaderBytes(pgz) == hdr
            @test atlasHeaderBytes(pplain) == hdr
        end
    end

    @testset "openAtlas: clear AtlasFormatError on non-Atlas / malformed input" begin
        dir = mktempdir()

        # A single-line JSON document (e.g. a dual-graph file) -- the "throw away
        # initial line" read consumes the whole thing, so the header line is empty.
        notAnAtlas = joinpath(dir, "graph.json")
        write(notAnAtlas, """{"directed":false,"nodes":[{"id":0}]}""")
        io = smartOpen(notAnAtlas, "r")
        @test_throws AtlasFormatError openAtlas(io)
        close(io)

        # Header line parses as JSON but is missing a required key.
        missingKey = joinpath(dir, "missingkey.jsonl")
        write(missingKey, "banner\n" * """{"description":"d","date":"t","atlasParamType":"Dict"}""" * "\n{}\n")
        io2 = smartOpen(missingKey, "r")
        @test_throws AtlasFormatError openAtlas(io2)
        close(io2)

        # Header line names an unsupported weightType.
        badWeight = joinpath(dir, "badweight.jsonl")
        write(badWeight, "banner\n" *
              """{"description":"d","date":"t","atlasParamType":"Dict","mapParamType":"Dict","weightType":"BigFloat"}""" *
              "\n{}\n")
        io3 = smartOpen(badWeight, "r")
        @test_throws AtlasFormatError openAtlas(io3)
        close(io3)

        # Third line (atlas parameters) isn't valid JSON.
        badParams = joinpath(dir, "badparams.jsonl")
        write(badParams, "banner\n" *
              """{"description":"d","date":"t","atlasParamType":"Dict","mapParamType":"Dict"}""" *
              "\nnot json\n")
        io4 = smartOpen(badParams, "r")
        @test_throws AtlasFormatError openAtlas(io4)
        close(io4)

        # AtlasFormatError <: Exception and carries a readable message.
        try
            io5 = smartOpen(notAnAtlas, "r")
            openAtlas(io5)
        catch e
            @test e isa AtlasFormatError
            @test occursin("not a valid Atlas file", e.msg)
            @test occursin("not a valid Atlas file", sprint(showerror, e))
        end
    end

    @testset "getFileExtension with no dot" begin
        ext, base = AtlasIO.getFileExtension("noext")
        @test ext == ""
        @test base == "noext"
    end

    @testset "smartOpen: real errors aren't masked as missing-file" begin
        # A permission-denied file gives EACCES, not ENOENT, so smartOpen must
        # propagate it rather than silently retrying with an alternate extension.
        dir = mktempdir()
        path = joinpath(dir, "secret.jsonl")
        write(path, "x")
        chmod(path, 0o000)
        try
            @test_throws SystemError smartOpen(path, "r")
        finally
            chmod(path, 0o644)   # restore so mktempdir's cleanup can remove it
        end
    end

    @testset "nextMap/skipMap past EOF raise EOFError" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        while !eof(atlas); nextMap(atlas); end
        @test_throws EOFError nextMap(atlas)
        close(io)

        io2 = smartOpen(atlasFileName, "r")
        atlas2 = openAtlas(io2)
        @test_throws EOFError skipMap(atlas2; numSkip=TOTAL_MAPS + 1)
        close(io2)

        io3 = smartOpen(atlasFileName, "r")
        atlas3 = openAtlas(io3)
        iter = eachline(atlas3.io)
        for _ in 1:TOTAL_MAPS; nextMap(atlas3, iter); end
        @test_throws EOFError nextMap(atlas3, iter)
        close(io3)
    end

    @testset "nextMap/parseBufferToMap raise AtlasFormatError on malformed map line" begin
        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        @test_throws AtlasFormatError parseBufferToMap(atlas, "not json")
        close(io)

        dir = mktempdir()
        badMap = joinpath(dir, "badmap.jsonl")
        write(badMap, "banner\n" *
              """{"description":"d","date":"t","atlasParamType":"Dict","mapParamType":"Dict"}""" *
              "\n{}\nnot a map line\n")
        io2 = smartOpen(badMap, "r")
        atlas2 = openAtlas(io2)
        @test_throws AtlasFormatError nextMap(atlas2)
        close(io2)
    end

end
