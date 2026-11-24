# eachMap / eachMapData against the nextMap loop, on a whole (or the first MAX maps of an) atlas file:
#
#     julia --project=. -t 8 benchmark/bench_eachmap.jl ATLAS [MAX]
#     julia --project=. -t 1 benchmark/bench_eachmap.jl ATLAS [MAX]
#
# Each method reads the file from disk (decompression included), once, after a warm-up on a few maps.
# Reports µs per map, MB/s of uncompressed map-line JSON, and the share of time spent in GC.
#
# Measured 2026-11-24 (Apple silicon, Julia 1.13; µs/map, speedup over the nextMap loop):
#
#   atlas                                   threads  nextMap loop  eachMap        eachMapData   readline only
#   NC multiscale, 79,997 maps, 28 KB/line     8         942       356 (2.64x)    133 (7.1x)        129
#   CycleWalk NC, 10,001 maps, 66 KB/line      8        2459      1083 (2.27x)    404 (6.1x)        394
#   NC multiscale                              1         894       946 (0.95x)    152 (5.9x)        125
#   CycleWalk NC                               1        2203      2205 (1.00x)    381 (5.8x)        380
#
# Per-map cost scales with line size; eachMapData runs at the decompression floor; parallel eachMap is limited
# by parsing and GC (30-36% of its time). Batch sizes 16-1024 on 8 threads were within ~20% of each other.

using AtlasIO

const ATLAS = ARGS[1]
const MAX = length(ARGS) >= 2 ? parse(Int, ARGS[2]) : typemax(Int)

function readlines_only(path, max)
    io = smartOpen(path, "r"); a = openAtlas(io); n = 0; bytes = 0
    while !eof(a.io) && n < max
        bytes += sizeof(readline(a.io)); n += 1
    end
    close(io); (n, bytes)
end
function loop(path, max, next)
    io = smartOpen(path, "r"); a = openAtlas(io); n = 0
    while !eof(a) && n < max
        next(a); n += 1
    end
    close(io); n
end
function iter(path, max, each; kw...)
    n = 0
    for _ in each(path; max = max, kw...)
        n += 1
    end
    n
end

methods = [
    "readline only (floor)" => (p, m) -> readlines_only(p, m)[1],
    "nextMap loop"          => (p, m) -> loop(p, m, nextMap),
    "eachMap batch=1"       => (p, m) -> iter(p, m, eachMap; batch = 1),
    "eachMap (default)"     => (p, m) -> iter(p, m, eachMap),
    "nextMapData loop"      => (p, m) -> loop(p, m, nextMapData),
    "eachMapData (default)" => (p, m) -> iter(p, m, eachMapData),
]

nmaps, bytes = readlines_only(ATLAS, MAX)
mb = bytes / 1e6
println(basename(ATLAS), ": ", nmaps, " maps, ", round(Int, bytes / nmaps / 1e3), " KB/line, ",
        round(Int, mb), " MB uncompressed; ", Threads.nthreads(), " threads, Julia ", VERSION)

for (_, f) in methods
    f(ATLAS, 300)                                  # warm-up / compile
end
GC.gc()

base = 0.0
for (label, f) in methods
    GC.gc()
    s = @timed f(ATLAS, MAX)
    s.value == nmaps || error("$label read $(s.value) maps, expected $nmaps")
    label == "nextMap loop" && (global base = s.time)
    speed = base > 0 ? string(round(base / s.time, digits = 2), "x") : ""
    println(rpad(label, 23), lpad(round(Int, 1e6 * s.time / nmaps), 7), " µs/map ",
            lpad(round(Int, mb / s.time), 6), " MB/s   GC ", lpad(round(Int, 100 * s.gctime / s.time), 3), "%  ",
            lpad(speed, 6))
end
