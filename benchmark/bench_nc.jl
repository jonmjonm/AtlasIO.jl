# Read/write throughput on an NC example atlas. Uses only functions every AtlasIO version since 0.1.4 has,
# so the same script can compare versions:
#
#     julia --project=. benchmark/bench_nc.jl [ATLAS] [LABEL]
#     julia --project=ENV_WITH_ATLASIO_0_1_5 benchmark/bench_nc.jl [ATLAS] 0.1.5
#
# ATLAS defaults to ExampleAtlas/atlas_truncated_nc_multiscale.jsonl (20 maps, ~28 KB per map line).
# Reports MB/s of uncompressed map-line JSON: the minimum time of several runs, single-threaded.

using AtlasIO

const ATLAS = length(ARGS) >= 1 ? ARGS[1] : joinpath(@__DIR__, "..", "ExampleAtlas", "atlas_truncated_nc_multiscale.jsonl")
const LABEL = length(ARGS) >= 2 ? ARGS[2] : string(pkgversion(AtlasIO))

io = smartOpen(ATLAS, "r")
atlas = openAtlas(io)
lines = String[]
while !eof(atlas.io)
    push!(lines, readline(atlas.io))
end
close(io)
maps = [parseBufferToMap(atlas, l) for l in lines]
mb = sum(sizeof, lines) / 1e6

best(f; n = 7) = (f(); minimum(@elapsed(f()) for _ in 1:n))
reps = max(1, round(Int, 20 / mb))                 # ~20 MB of JSON per timing
tMap = best(() -> for _ in 1:reps, l in lines; parseBufferToMap(atlas, l); end)
tData = best(() -> for _ in 1:reps, l in lines; parseBufferToMapData(atlas, l); end)
tWrite = best(() -> (out = IOBuffer(); for _ in 1:reps, m in maps; addMap(out, m); end))

rate(t) = round(reps * mb / t, digits = 1)
println(rpad(LABEL, 14), " read Map: ", lpad(rate(tMap), 7), " MB/s   read MapData: ", lpad(rate(tData), 8),
        " MB/s   write: ", lpad(rate(tWrite), 7), " MB/s   (", length(lines), " maps, ",
        round(Int, mb * 1e3 / length(lines)), " KB/line, Julia ", VERSION, ", ", Threads.nthreads(), " thread)")
