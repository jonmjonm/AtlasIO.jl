# Streaming read and threaded read/write on the full NC atlas (ExampleAtlas/atlas_nc_multiscale.jsonl.gz,
# 79,997 maps, ~2.3 GB uncompressed). Uses only functions AtlasIO 0.1.5 also has, to compare versions:
#
#     julia -t auto --project=. benchmark/bench_full.jl [NMAPS] [LABEL]
#     julia -t auto --project=ENV_WITH_ATLASIO_0_1_5 benchmark/bench_full.jl [NMAPS] 0.1.5
#
# NMAPS (default 5000) maps are read from the start of the gzip file each time, so read times include
# gunzip. Rates are MB/s of uncompressed map-line JSON.

using AtlasIO

const ATLAS = joinpath(@__DIR__, "..", "ExampleAtlas", "atlas_nc_multiscale.jsonl.gz")
const N = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 5000
const LABEL = length(ARGS) >= 2 ? ARGS[2] : string(pkgversion(AtlasIO))

function readN(f)
    io = smartOpen(ATLAS, "r")
    atlas = openAtlas(io)
    out = f(atlas)
    close(io)
    return out
end
serialMaps(atlas) = [nextMap(atlas) for _ in 1:N]
serialData(atlas) = [nextMapData(atlas) for _ in 1:N]
threadedMaps(atlas) = nextMaps(atlas; n = N)
function rawBytes(atlas)
    nb = 0
    for _ in 1:N
        nb += sizeof(readline(atlas.io))
    end
    return nb
end

best(f; n = 3) = (f(); minimum(@elapsed(f()) for _ in 1:n))
mb = readN(rawBytes) / 1e6
maps = readN(serialMaps)
rate(t) = lpad(round(mb / t, digits = 1), 7)

t_gunzip = best(() -> readN(rawBytes))
t_map = best(() -> readN(serialMaps))
t_data = best(() -> readN(serialData))
t_thr = best(() -> readN(threadedMaps))
t_w1 = best(() -> (io = IOBuffer(); foreach(m -> addMap(io, m), maps)))
t_wN = best(() -> addMaps(IOBuffer(), maps))

println(rpad(LABEL, 10), " threads=", Threads.nthreads(), "  ", N, " maps, ", round(Int, mb), " MB JSON")
println("   gunzip+readline only : ", rate(t_gunzip), " MB/s")
println("   nextMap   (serial)   : ", rate(t_map), " MB/s")
println("   nextMapData (serial) : ", rate(t_data), " MB/s")
println("   nextMaps  (threaded) : ", rate(t_thr), " MB/s")
println("   addMap    (serial)   : ", rate(t_w1), " MB/s")
println("   addMaps   (threaded) : ", rate(t_wN), " MB/s")
