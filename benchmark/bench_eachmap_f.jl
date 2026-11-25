# eachMap(f) against calling f in the body of an eachMap loop, and against the pattern AtlasUtilities uses
# (read a batch of lines serially, then parse and compute in parallel with its readBatch/parallelDo! helpers,
# copied here), for light and heavy per-map work:
#
#     julia --project=. -t 8 benchmark/bench_eachmap_f.jl ATLAS MAX
#
# Measured 2026-11-24 (Apple silicon, Julia 1.13, 8 threads; µs per map; "heavy" is a synthetic ~1-4 ms of CPU):
#
#   atlas                                   work    AtlasUtilities  eachMap, f in loop  eachMap(f)
#   CycleWalk NC, 3,000 maps, 66 KB/line    light       1114            1378            1067
#   CycleWalk NC                            heavy       1597            5358            1610
#   NC multiscale, 10,000 maps, 28 KB/line  light        385             450             371
#   NC multiscale                           heavy        690            2642             680
#
# eachMap(f) runs f in the parse tasks and keeps only f's results, so it matches the AtlasUtilities pattern; f in
# the loop body runs serially, and holding a batch of parsed maps costs GC time.

using AtlasIO

const P = ARGS[1]; const MAX = parse(Int, ARGS[2])
const BATCH = 512
function readBatch(io, cap::Int = BATCH)
    lines = String[]; while length(lines) < cap && !eof(io); push!(lines, readline(io)); end; lines
end
function chunkranges(n, k)
    k = clamp(k, 1, max(n, 1)); base, extra = divrem(n, k); rs = UnitRange{Int}[]; s = 1
    for c in 1:k; len = base + (c <= extra ? 1 : 0); len == 0 && continue; push!(rs, s:s+len-1); s += len; end; rs
end
parallelDo!(f, n, cores) = (@sync for r in chunkranges(n, cores); Threads.@spawn for i in r; f(i); end; end; nothing)

light(m) = Float64(length(m.districting) + sum(values(m.districting)))
function heavy(m)            # stand-in for a writer: ~1-2 ms of CPU per map
    s = 0.0
    for _ in 1:40, (k, v) in m.districting
        s += (hash(k) % 7) * v
    end
    s
end
function au(w)
    io = smartOpen(P, "r"); a = openAtlas(io); mpt, wt = a.mapParamType, a.weightType
    tot = 0.0; got = 0
    while !eof(a) && got < MAX
        lines = readBatch(a.io, min(BATCH, MAX - got)); n = length(lines)
        r = Vector{Float64}(undef, n)
        parallelDo!(i -> (r[i] = w(parseMap(lines[i], mpt, wt))), n, Threads.nthreads())
        for x in r; tot += x; end; got += n
    end
    close(io); (got, tot)
end
loopwork(w) = (got = 0; tot = 0.0; for m in eachMap(P; max = MAX); tot += w(m); got += 1; end; (got, tot))
fwork(w)    = (got = 0; tot = 0.0; for x in eachMap(w, P; max = MAX); tot += x; got += 1; end; (got, tot))

for (wl, w) in ("light work" => light, "heavy work" => heavy)
    cases = ["AU readBatch/parallelDo!" => () -> au(w),
             "eachMap, work in loop"    => () -> loopwork(w),
             "eachMap(f), work in tasks" => () -> fwork(w)]
    ref = nothing
    for (_, f) in cases; f(); end
    println("-- ", wl)
    for (l, f) in cases
        GC.gc(); s = @timed f()
        got, tot = s.value
        ref === nothing && (ref = tot); tot == ref || error("$l: different result")
        println("  ", rpad(l, 28), lpad(round(Int, 1e6 * s.time / got), 6), " µs/map  GC ", lpad(round(Int, 100 * s.gctime / s.time), 3), "%")
    end
end
