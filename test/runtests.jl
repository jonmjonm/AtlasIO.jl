using Test
using AtlasIO

atlasFileName = joinpath(@__DIR__, "test.jsonl")  # Path to your test file
atlasFileNameGziped = joinpath(@__DIR__, "test.jsonl.gz")  # Path to your test file
first_map_truth= Dict{Tuple{Vararg{String}}, Int64}(("p2", "c2") => 1, ("p1", "c2") => 1, ("p3", "c7", "b100") => 2)
second_map_truth=Dict{Tuple{Vararg{String}}, Int64}(("p2", "c2") => 2, ("p1", "c2") => 1, ("p3", "c7", "b100") => 1)
@testset verbose = true "Atlas Tests" begin
    @testset "Uncompressed Atlas Reading" begin

        io = smartOpen(atlasFileName, "r")
        atlas = openAtlas(io)
        @test !eof(atlas)  # The atlas should have content
        @test atlas.description == "Test Atlas"  # Replace with expected description

        # Read the first map and check its properties
        first_map = nextMap(atlas)
        # Example checks — adapt to your test file fields
        @test first_map.name == "map1"  # Replace "map1" with expected map name
        @test length(first_map.districting) == 3  # Replace 100 with expected size
        @test first_map.districting == first_map_truth  # Check if the first map matches the expected structure
        
        second_map = nextMap(atlas)
        @test second_map.name == "map2"  # Replace "map1" with expected map name
        @test length(second_map.districting) == 3  # Replace 100 with expected size
        @test second_map.districting == second_map_truth  # Check if the first map matches the expected structure


        # Clean up
        close(io)
    end

    @testset "Compressed Atlas Reading" begin

        io = smartOpen(atlasFileNameGziped, "r")
        atlas = openAtlas(io)
        @test !eof(atlas)  # The atlas should have content
        @test atlas.description == "Test Atlas"  # Replace with expected description

        # Read the first map and check its properties
        first_map = nextMap(atlas)
        # Example checks — adapt to your test file fields
        @test first_map.name == "map1"  # Replace "map1" with expected map name
        @test length(first_map.districting) == 3  # Replace 100 with expected size
        @test first_map.districting == first_map_truth  # Check if the first map matches the expected structure
        
        second_map = nextMap(atlas)
        @test second_map.name == "map2"  # Replace "map1" with expected map name
        @test length(second_map.districting) == 3  # Replace 100 with expected size
        @test second_map.districting == second_map_truth  # Check if the first map matches the expected structure


        # Clean up
        close(io)
    end;
end;