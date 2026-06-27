using Test
using AtlasIO

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

end
