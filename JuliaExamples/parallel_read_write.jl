##
## Multithreaded reading and writing of an Atlas.
##
## readMapsParallel parses the maps across all available threads (the JSON parse
## is ~97% of read time and is independent per map). addMaps serializes maps in
## parallel and writes them in order. Both produce results identical to the
## serial nextMap / addMap paths.
##
## IMPORTANT: start Julia with multiple threads, otherwise these run serially:
#   julia -t auto parallel_read_write.jl <atlas name> [num maps] [out atlas]
#
## Usage
# julia -t auto parallel_read_write.jl <atlas name> <optional: num maps> <optional: out atlas>
#
## Examples
# julia -t auto parallel_read_write.jl ../ExampleAtlas/atlas_truncated_nc_multiscale.jsonl
# julia -t auto parallel_read_write.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 2000
# julia -t auto parallel_read_write.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 2000 copy.jsonl

using AtlasIO
using Printf
@show ARGS

atlasFileName = ARGS[1]                          # input atlas
maxMap  = length(ARGS) > 1 ? parse(Int64, ARGS[2]) : typemax(Int)  # cap on maps to read
outName = length(ARGS) > 2 ? ARGS[3] : nothing   # optional output atlas

println("Running with ", Threads.nthreads(), " thread(s) on file ", atlasFileName)
if Threads.nthreads() == 1
    @warn "Only 1 thread available — restart with `julia -t auto` to see the speedup."
end

################
# Parallel read
################
io = smartOpen(atlasFileName, "r")
atlas = openAtlas(io)
println("atlas date:", atlas.date)
println("number of districts:", atlas.atlasParam["districts"])

t = @timed maps = readMapsParallel(atlas; n = maxMap)   # Vector{Map}, in on-disk order
close(atlas)

@printf("read %d maps in %.3f s (%.0f maps/s)\n", length(maps), t.time, length(maps) / t.time)
for (i, m) in enumerate(maps[1:min(end, 3)])
    println("  map ", i, ": name=", m.name,
            "  weight=", m.weight,
            "  assignments=", length(m.districting))
end

################
# Parallel write (optional)
################
if outName !== nothing
    # Copy the original 3-line header verbatim, then append the maps in parallel.
    copyAtlasHeader(atlasFileName, outName)
    ioOut = smartOpen(outName, "a")
    tw = @timed nbytes = addMaps(ioOut, maps)
    close(ioOut)
    @printf("wrote %d maps (%d bytes) in %.3f s (%.0f maps/s) to %s\n",
            length(maps), nbytes, tw.time, length(maps) / tw.time, outName)

    # Verify the round-trip: re-read the output and compare to what we wrote.
    ioCheck = smartOpen(outName, "r")
    atlasCheck = openAtlas(ioCheck)
    back = readMapsParallel(atlasCheck)
    close(atlasCheck)
    ok = length(back) == length(maps) &&
         all(back[i].name == maps[i].name &&
             back[i].districting == maps[i].districting for i in eachindex(maps))
    println("round-trip matches original: ", ok)
end
