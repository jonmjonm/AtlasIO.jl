# Test F, step 1 of 3: write Atlas files with the CURRENT AtlasIO, for AtlasIO 0.1.5 to read (step 3).
#
#     julia --project=. test/compat/write_with_current.jl OUTDIR
#
# Writes into OUTDIR:
#   * every frozen v1 fixture and the NC example atlas, re-written map by map (header bytes copied, maps
#     re-serialized with mapBytes) through AtlasOutput as plain, multi-member gzip and bzip2;
#   * a seeded random atlas written with newAtlas + addMaps (plain and gzip), including big integers, -0.0,
#     awkward names and the value types AtlasStyle handles (Rational, DateTime, matrices).
# Step 2 (make_compat_expected.py) computes the expected values from these files with Python's json.

using AtlasIO, Dates
using Random: Xoshiro

length(ARGS) == 1 || error("usage: julia --project=. test/compat/write_with_current.jl OUTDIR")
const OUT = ARGS[1]
mkpath(OUT)
const REPO = normpath(joinpath(@__DIR__, "..", ".."))

sources = [joinpath(REPO, "test", "fixtures", "v1", f) for f in ("edge.jsonl", "edge_float.jsonl", "python_written.jsonl")]
push!(sources, joinpath(REPO, "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl"))

for src in sources
    io = smartOpen(src, "r")
    atlas = openAtlas(io)
    maps = Map[]
    while !eof(atlas)
        push!(maps, nextMap(atlas))
    end
    close(io)
    stem = replace(basename(src), ".jsonl" => "")
    for ext in (".jsonl", ".jsonl.gz", ".jsonl.bz2")
        out = openAtlasOutput(joinpath(OUT, "rewritten_" * stem * ext), atlasHeaderBytes(src))
        writeMaps!(out, mapBytes.(maps))
        close(out)
    end
end

# Seeded random atlas through newAtlas + addMaps.
rng = Xoshiro(20261123)
chars = collect("aZ09 \"\\,[]{}:'/éñ中😀")
rname() = String(rand(rng, chars, rand(rng, 1:8)))
maps = Map{Dict{String,Any}}[]
for i in 1:100
    d = Districting()
    for _ in 1:rand(rng, 0:25)
        d[Tuple(rname() for _ in 1:rand(rng, 1:3))] = rand(rng, 1:20)
    end
    data = Dict{String,Any}("f" => [rand(rng) * 10.0^rand(rng, -8:8) for _ in 1:3], "i" => rand(rng, Int64, 2),
                            "z" => [-0.0, 0.0, 1.0], "s" => rname())
    i == 1 && merge!(data, Dict{String,Any}("rational" => 1//3, "datetime" => DateTime(2026, 11, 23, 1, 2, 3),
                                            "matrix" => [1 2; 3 4], "max" => typemax(Int64)))
    push!(maps, Map{Dict{String,Any}}(rname(), d, rand(rng, 1:10), data))
end
header = AtlasHeader("test F random atlas", "2026-11-23T00:00:00", "Dict{String, Any}", "Dict{String, Any}")
params = Dict{String,Any}("levels in graph" => ["county", "prec_id"], "gamma" => 0.0, "seed" => -7375463094308724563)
for ext in (".jsonl", ".jsonl.gz")
    io = smartOpen(joinpath(OUT, "random" * ext), "w")
    newAtlas(io, header, params)
    addMaps(io, maps)
    close(io)
end

println("test F step 1: wrote ", length(readdir(OUT)), " files to ", OUT, " with AtlasIO ", pkgversion(AtlasIO))
