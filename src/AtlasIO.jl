module AtlasIO

using StructTypes, JSON3, Dates
using TranscodingStreams, CodecBzip2, CodecZlib


export Map,
    smartOpen,
    AtlasHeader,
    AtlasFormatError,
    Atlas,
    Districting,
    newAtlas,
    openAtlas,
    nextMap,
    nextMaps,
    addMap,
    addMaps,
    close,
    smartOpen,
    skipMap,
    eof,
    copyAtlasHeader,
    parseBufferToMap,
    AtlasOutput,
    openAtlasOutput,
    writeMaps!,
    writeGzipMembers!,
    groupByBytes,
    gzipMember,
    isGzipOutput,
    atlasHeaderBytes,
    GZIP_MEMBER_TARGET

struct AtlasHeader
    description::String
    date::String
    atlasParamType::String
    mapParamType::String
    weightType::String #currently unused
end
StructTypes.StructType(::Type{AtlasHeader}) = StructTypes.Struct()

AtlasHeader(name::String,date::String,atlasParamType::DataType,mapParamType::DataType; weightType::DataType=Int64)=AtlasHeader(name,date,string(atlasParamType),string(mapParamType),string(weightType))
AtlasHeader(name::String,atlasParamType::DataType,mapParamType::DataType; weightType::DataType=Int64)=AtlasHeader(name,string(now()),string(atlasParamType),string(mapParamType),string(weightType))
# Back-compat: pre-float_weights headers had no weightType; default it to Int64
AtlasHeader(name::String,date::String,atlasParamType::String,mapParamType::String; weightType::String="Int64")=AtlasHeader(name,date,atlasParamType,mapParamType,weightType)
    
struct Atlas{T}
    io::IO
    description::String
    date::String
    atlasParam::T
    mapParamType::DataType
    weightType::DataType
end
Atlas{T}(io::IO,atlasHeader::AtlasHeader,atlasParam::T) where T =Atlas(io,atlasHeader.description,atlasHeader.date,atlasParam,atlasHeader.mapParamType,atlasHeader.weightType)
# Back-compat: pre-float_weights callers passed 5 positional args (no weightType); default it to Int64
Atlas{T}(io::IO,description::String,date::String,atlasParam::T,mapParamType::DataType) where T =Atlas(io,description,date,atlasParam,mapParamType,Int64)

Districting=Dict{Tuple{Vararg{String}},Int64} #Dict{String,Int64}

Base.@kwdef struct Map{T,W<: Real} # T is the data type of the Data about them map. Dict must us string keys
    name::String
    districting::Districting
    weight::W
    data::T
end

function parseDistrictKey(s::AbstractString)
    toks=String[]
    cu=codeunits(s)
    i=1; n=length(cu)
    @inbounds while i<=n
        if cu[i]==UInt8('"')
            i+=1
            buf=IOBuffer()
            while i<=n && cu[i]!=UInt8('"')
                (cu[i]==UInt8('\\') && i<n) && (i+=1)
                write(buf,cu[i]); i+=1
            end
            push!(toks,String(take!(buf)))
        end
        i+=1
    end
    return Tuple(toks)
end

function Map{T,W}(x::Dict{String, Any}) where {T<:Any, W<:Real}
    dict=Dict{Tuple{Vararg{String}}, Int64}()
    for x in x["districting"]
        for (k,v) in x
                kk=parseDistrictKey(k)
                dict[kk]=v
        end
    end
    return Map(x["name"],dict,W(x["weight"]),T(x["data"]))
end
# Back-compat: allow constructing a Map with only the data type parameter;
# the weight type W is inferred from the supplied weight (defaults to Int64-style ints).
Map{T}(; name, districting, weight, data) where T = Map{T,typeof(weight)}(name, districting, weight, data)
Map{T}(name, districting, weight, data) where T = Map{T,typeof(weight)}(name, districting, weight, data)

StructTypes.StructType(::Type{<:Map}) = StructTypes.CustomStruct()

function districtKeyString(k)
    buf=IOBuffer()
    write(buf,'[')
    first=true
    for s in k
        first ? (first=false) : write(buf,", ")
        write(buf,'"')
        for c in codeunits(s)
            (c==UInt8('"') || c==UInt8('\\')) && write(buf,UInt8('\\'))
            write(buf,c)
        end
        write(buf,'"')
    end
    write(buf,']')
    return String(take!(buf))
end

StructTypes.lower(x::Map{T,W} where {T, W<:Real}) = (name=x.name, weight=x.weight, data=x.data, districting=[districtKeyString(k) => v for (k, v) in x.districting])

function newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam)
    JSON3.write(io,"This is an Atlas for Redistricting Maps. See 'https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md' for more information about the format.")
    write(io,"\n")
    JSON3.write(io,atlasHeader)
    write(io,"\n")
    JSON3.write(io,atlasParam)
    write(io,"\n")
end

const types=Dict{String,DataType}("Int64"=>Int64,"Float64"=>Float64)

"""
    AtlasFormatError(msg) <: Exception

Raised by [`openAtlas`](@ref) when the input stream's first three lines don't
parse as a valid Atlas header -- e.g. the file is some other JSON document
(a dual-graph file, say) rather than an Atlas, or it's truncated. Carries a
plain-text `msg` describing what went wrong.
"""
struct AtlasFormatError <: Exception
    msg::String
end
Base.showerror(io::IO, e::AtlasFormatError) = print(io, "AtlasFormatError: ", e.msg)

function openAtlas(io::IO)::Atlas
    readline(io) #throw away initial line (the human-readable format banner)

    headerLine = readline(io)
    local atlasHeaderDict
    try
        atlasHeaderDict = JSON3.read(headerLine, Dict{String,String})
    catch e
        throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) " *
                               "did not parse as JSON ($(sprint(showerror, e)))."))
    end

    for k in ("description", "date", "atlasParamType", "mapParamType")
        haskey(atlasHeaderDict, k) ||
            throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) " *
                                   "is missing \"$k\"."))
    end

    if !haskey(atlasHeaderDict,"weightType")
        #missing weightType, adding default Int64
        atlasHeaderDict["weightType"]="Int64"
    end
    haskey(types, atlasHeaderDict["weightType"]) ||
        throw(AtlasFormatError("not a valid Atlas file: unknown weightType " *
                               "\"$(atlasHeaderDict["weightType"])\" (expected " *
                               "\"Int64\" or \"Float64\")."))

    atlasHeader=AtlasHeader(atlasHeaderDict["description"],atlasHeaderDict["date"],atlasHeaderDict["atlasParamType"],atlasHeaderDict["mapParamType"],atlasHeaderDict["weightType"])
    atlas_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.atlasParamType))
    map_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.mapParamType))
    weight_type=types[atlasHeader.weightType] #ensure weight type is defined

    paramLine = readline(io)
    local atlasParam
    try
        atlasParam = JSON3.read(paramLine, atlas_ParamType)
    catch e
        throw(AtlasFormatError("not a valid Atlas file: the atlas-parameters line " *
                               "(line 3) did not parse as JSON ($(sprint(showerror, e)))."))
    end

    atlas=Atlas{map_ParamType}(io,atlasHeader.description,atlasHeader.date,atlasParam,map_ParamType, weight_type)

    return atlas
end
    
function nextMap(atlas::Atlas)::Map
    buff=readline(atlas.io)
    map=JSON3.read(buff,Map{atlas.mapParamType,atlas.weightType})
    return map
end

function parseBufferToMap(atlas::Atlas,buff::String)::Map
    map=JSON3.read(buff,Map{atlas.mapParamType,atlas.weightType})
    return map
end
function nextMap(atlas::Atlas,ioIterator::Base.EachLine)::Map
    buff=first(ioIterator)
    map=JSON3.read(buff,Map{atlas.mapParamType,atlas.weightType})
    return map
end

"""
    nextMaps(atlas::Atlas; n=typemax(Int), batch=256) -> Vector{Map}

Read up to `n` maps from `atlas`, parsing them across all available threads.

The bottleneck on the read path is JSON parsing + `Map` construction (~97% of the
time); the actual stream `readline`/decompression is cheap and inherently serial
(one compressed stream). This function reads lines serially in chunks of `batch`
while parsing each chunk in parallel with `Threads.@threads`. The next chunk is
prefetched on a separate task so its decompression overlaps with parsing of the
current chunk.

Returned maps are in on-disk order — identical to a serial
`while !eof(atlas); nextMap(atlas); end` loop. Reading continues from wherever
`atlas` is currently positioned, so this composes with `skipMap`/`nextMap`.

Start Julia with multiple threads (e.g. `julia -t auto`) to benefit; with a
single thread it runs serially with negligible overhead.
"""
function nextMaps(atlas::Atlas; n::Integer=typemax(Int), batch::Integer=256)
    batch < 1 && throw(ArgumentError("batch must be ≥ 1"))
    MT = Map{atlas.mapParamType}
    out = MT[]

    # Read up to `k` lines from the stream (fewer if EOF is reached first).
    function readchunk(k::Int)
        lines = String[]
        sizehint!(lines, k)
        while length(lines) < k && !eof(atlas)
            push!(lines, readline(atlas.io))
        end
        return lines
    end

    got = 0
    pending = Threads.@spawn readchunk(min(batch, n - got))
    while true
        # `fetch` blocks until the prefetch task finishes, so the chunk it read
        # is complete before we reassign any of the variables it captured.
        lines = fetch(pending)::Vector{String}
        isempty(lines) && break
        nread = length(lines)
        got += nread
        # Kick off the next read so it overlaps the parsing below.
        k = clamp(n - got, 0, batch)
        pending = Threads.@spawn readchunk(k)
        base = length(out)
        resize!(out, base + nread)
        Threads.@threads for i in 1:nread
            @inbounds out[base + i] = parseBufferToMap(atlas, lines[i])
        end
    end
    return out
end

function addMap(io::IO,map::Map{T}) where T
    buff=JSON3.write(map)
    write(io,buff)+write(io,"\n")
end

function addMap(io::IO,dist::Districting,name::String,w::Real,mapParams)
   addMap(io,Map{typeof(mapParams)}(name,dist,w,mapParams))
end

"""
    addMaps(io::IO, maps) -> Int

Write a collection of `Map`s to `io`. JSON serialization (the bottleneck on the
write path) is done in parallel across threads, then the resulting strings are
written to `io` serially in order. The output is byte-identical to calling
`addMap(io, m)` for each map in turn. Returns the total number of bytes written.

Start Julia with multiple threads (e.g. `julia -t auto`) to benefit; with a
single thread it runs serially with negligible overhead.
"""
function addMaps(io::IO, maps)
    ms = collect(maps)                       # ensure 1-based, indexable
    strs = Vector{String}(undef, length(ms))
    Threads.@threads for i in eachindex(ms)
        @inbounds strs[i] = JSON3.write(ms[i])
    end
    nb = 0
    @inbounds for i in eachindex(ms)
        nb += write(io, strs[i]) + write(io, "\n")
    end
    return nb
end

function Base.close(atlas::Atlas)
    Base.close(atlas.io)
end

"""
opens an IO stream which is wrapped in a compression pipe 
if the filename extension suggests it. Currently supports .gz and .bz2.
Defaults to regular uncompressed writing/reading if not one of these extensions.
Returns *nothing* if unsure what to do.
"""
function smartOpen(fileName::String, io_mode::String)::Union{IO,Nothing}
    ext,base=getFileExtension(fileName)
 
    if ((io_mode=="w") |(io_mode=="a"))
        
        oo= try open(fileName,io_mode) #try to open filename given
        catch err
            @info( string("Error opening file. Trying alternative extensions for ",fileName));
            if ((io_mode=="a") & ((ext==".gz") | (ext==".bz2")))
                fileName=base;
                ext,base=getFileExtension(base);
                open(base,io_mode) #if first open fails and was compressed, try not compressed
            else
                base=string(base,ext);
                ext=".gz";
                fileName=string(base,ext);
                open(fileName,io_mode) #if first open fails and was not compressed, try  compressed
            end
        end
        if ext==".bz2"
            # print("w-bZ")
            return Bzip2CompressorStream(oo)
        end
        if ext==".gz"
            # print("w-gZ")
            return GzipCompressorStream(oo)
        end
        return oo  
    end
    
    if io_mode=="r" 
        
            oo= try open(fileName,io_mode) #try to open filename given
             catch err
                @info( string("Error opening file. Trying alternative extensions for ",fileName));
                if ((ext==".gz") | (ext==".bz2"))
                    fileName=base;
                    ext,base=getFileExtension(base);
                    oo=open(fileName,io_mode) #if first open fails and was compressed, try not compressed
                else
                    base=string(base,ext);
                    ext=".gz";
                    fileName=string(base,ext);
                    open(fileName,io_mode) #if first open fails and was not compressed, try  compressed
            end
        end
        if ext==".bz2"
            # print("r-bZ")
            return Bzip2DecompressorStream(oo)
        end
        if ext==".gz"
            # print("r-gZ")
            return GzipDecompressorStream(oo)
        end
        return oo
    end
    
    if ext==".bz2"
            return nothing
    end
    if ext==".gz"
            return nothing
    end
    oo=open(fileName,io_mode)
    return oo
end

function Base.eof(atlas::Atlas)::Bool
    return (Base.eof(atlas.io))
end

function skipMap(atlas::Atlas;numSkip=1)
    count=0
    while (count < numSkip)
        readline(atlas.io)
        count+=1
    end
end


function getFileExtension(filename::String)
    i=findlast(isequal('.'),filename)
    return filename[i:end],filename[1:i-1]
end

function copyAtlasHeader(sourceFilename::String, outFilename::String)
    ioSource=smartOpen(sourceFilename,"r")
    ioOut=smartOpen(outFilename,"w")
    for i=1:3
        buff=readline(ioSource)
        write(ioOut,buff)
        write(ioOut,"\n")
    end
    close(ioSource)
    close(ioOut)
end

# ---------------------------------------------------------------------------
# Parallel byte-targeted gzip output
# ---------------------------------------------------------------------------
#
# Writing a `.gz` atlas serially makes gzip's deflate() the dominant NON-parallel
# cost: `addMaps` already serializes maps in parallel, but the compression that
# follows runs single-threaded, capping thread scaling. The gzip format is a series
# of independent "members" that concatenate into one valid `.gz` (RFC 1952) -- read
# transparently by `gunzip`/`zcat` and by `openAtlas` here -- so the compression can
# be parallelized: group consecutive serialized maps until their combined size
# reaches a byte target, gzip each group into one member across worker tasks, and
# write the member bytes serially in order (the serial path is then just raw I/O).
#
# Grouping by BYTES (not map count) keeps every member comfortably above deflate's
# 32 KB history window, so the multi-member ratio penalty stays within ~0.1% of a
# single stream for any atlas -- large-map or small-map. The output is NOT
# byte-identical to a single-stream `.gz` (it is a different, equally valid encoding
# of the same content).
#
# `AtlasOutput` is the writer used by tools that already produce serialized map
# bytes (e.g. AtlasUtilities' `add`/`relabel`): `openAtlasOutput(path, header, ...)`
# then repeated `writeMaps!(out, bytes)` then `close(out)`. Only `.gz` targets take
# the parallel-member path; plain output is written directly and `.bz2` streams
# through `smartOpen`.

"Target uncompressed bytes per gzip member (256 KB -- 8x deflate's 32 KB window)."
const GZIP_MEMBER_TARGET = 1 << 18

"Compress `bytes` into one standalone gzip member (concatenable into a multi-member `.gz`)."
gzipMember(bytes::Vector{UInt8}) = transcode(GzipCompressor, bytes)

"True if writing `path` should produce gzip output (drives the parallel-member path);
`.bz2` is excluded and falls back to the serial stream."
isGzipOutput(path::AbstractString) = endswith(path, ".gz")

"""
    groupByBytes(sizes, target) -> Vector{UnitRange{Int}}

Partition `1:length(sizes)` into consecutive ranges whose summed `sizes` each reach
at least `target` bytes (the final range may be smaller). Each range becomes one
gzip member, so grouping by bytes keeps members above deflate's history window.
"""
function groupByBytes(sizes::Vector{Int}, target::Int)
    ranges = UnitRange{Int}[]
    n = length(sizes)
    i = 1
    while i <= n
        acc = 0
        j = i
        while j <= n && acc < target
            acc += sizes[j]
            j += 1
        end
        push!(ranges, i:(j - 1))
        i = j
    end
    return ranges
end

"Split `1:n` into at most `k` contiguous ranges (one per task)."
function _chunkranges(n::Int, k::Int)
    k = clamp(k, 1, max(n, 1))
    base, extra = divrem(n, k)
    ranges = UnitRange{Int}[]
    start = 1
    for c in 1:k
        len = base + (c <= extra ? 1 : 0)
        len == 0 && continue
        push!(ranges, start:(start + len - 1))
        start += len
    end
    return ranges
end

"""
    writeGzipMembers!(out, bytes, cores = Threads.nthreads(); target = GZIP_MEMBER_TARGET)

Write the in-order serialized records `bytes` to `out` as byte-targeted gzip members:
group consecutive records into ~`target`-byte groups (`groupByBytes`), gzip each
group into one member in parallel across `cores` tasks, then write the members to
`out` serially in record order (raw bytes -- the only serial work is I/O). The
concatenated members form one valid `.gz`. Returns nothing.
"""
function writeGzipMembers!(out::IO, bytes::Vector{Vector{UInt8}},
                           cores::Int = Threads.nthreads();
                           target::Int = GZIP_MEMBER_TARGET)
    isempty(bytes) && return nothing
    sizes = Int[length(b) for b in bytes]
    ranges = groupByBytes(sizes, target)
    members = Vector{Vector{UInt8}}(undef, length(ranges))
    @sync for cr in _chunkranges(length(ranges), cores)
        Threads.@spawn for gi in cr
            r = ranges[gi]
            buf = Vector{UInt8}(undef, sum(@view sizes[r]))
            off = 0
            for i in r
                b = bytes[i]
                copyto!(buf, off + 1, b, 1, length(b))
                off += length(b)
            end
            members[gi] = gzipMember(buf)
        end
    end
    for gi in eachindex(members)
        write(out, members[gi])
    end
    return nothing
end

"""
    AtlasOutput

Output sink for an atlas's serialized map bytes that hides how the target is
written. For a `.gz` path it emits byte-targeted gzip members compressed in parallel
(`writeGzipMembers!`); for any other path it writes through a `smartOpen` stream
(plain, or serial `.bz2`). Build with [`openAtlasOutput`](@ref), feed batches of
in-order serialized maps with [`writeMaps!`](@ref), and `close` it when done.
"""
struct AtlasOutput
    io::IO
    gzip::Bool
    cores::Int
end

"""
    openAtlasOutput(path, headerBytes, cores = Threads.nthreads()) -> AtlasOutput

Open `path` for writing and emit the atlas `headerBytes` (its three header lines).
For `.gz` output the header is written as its own gzip member and the file is opened
raw so subsequent map members can be appended; otherwise the header is written
through a `smartOpen` stream (plain or `.bz2`). `cores` is the parallel-compression
worker count for the map body.
"""
function openAtlasOutput(path::AbstractString, headerBytes::Vector{UInt8},
                         cores::Int = Threads.nthreads())
    if isGzipOutput(path)
        io = open(String(path), "w")
        write(io, gzipMember(headerBytes))
        return AtlasOutput(io, true, cores)
    else
        io = smartOpen(String(path), "w")   # plain IOStream or serial .bz2 stream
        write(io, headerBytes)
        return AtlasOutput(io, false, cores)
    end
end

"""
    writeMaps!(out::AtlasOutput, bytes)

Append the in-order serialized map byte-vectors `bytes` to `out`: as byte-targeted
parallel gzip members for a `.gz` target, or written straight through the stream
otherwise.
"""
function writeMaps!(out::AtlasOutput, bytes::Vector{Vector{UInt8}})
    if out.gzip
        writeGzipMembers!(out.io, bytes, out.cores)
    else
        for b in bytes
            write(out.io, b)
        end
    end
    return nothing
end

Base.close(out::AtlasOutput) = close(out.io)

"""
    atlasHeaderBytes(path) -> Vector{UInt8}

Read an atlas's three header lines from `path` as raw bytes (with trailing
newlines), for re-emitting through an [`AtlasOutput`](@ref).
"""
function atlasHeaderBytes(path::AbstractString)
    src = smartOpen(String(path), "r")
    buf = IOBuffer()
    for _ in 1:3
        write(buf, readline(src), "\n")
    end
    close(src)
    return take!(buf)
end

end # module AtlasIO
