module AtlasIO

using StructTypes, JSON3, Dates
using TranscodingStreams, CodecBzip2, CodecZlib


export Map, 
    smartOpen,
    AtlasHeader,
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
    parseBufferToMap

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

function openAtlas(io::IO)::Atlas
    #print("Entering openAtlas\n")
    
    buff=readline(io) #throw away initial line
    
    buff=readline(io)
    #@show buff
    atlasHeaderDict=JSON3.read(buff,Dict{String,String})
    #@show atlasHeaderDict
    #@show typeof(atlasHeaderDict)
    if !haskey(atlasHeaderDict,"weightType")
        #missing weightType, adding default Int64
        atlasHeaderDict["weightType"]="Int64"
    end
    #@show atlasHeaderDict

    atlasHeader=AtlasHeader(atlasHeaderDict["description"],atlasHeaderDict["date"],atlasHeaderDict["atlasParamType"],atlasHeaderDict["mapParamType"],atlasHeaderDict["weightType"])
    #atlasHeader=JSON3.read(buff,AtlasHeader)
    #@show atlasHeader
    #print("Convert Params in openAtlas\n")
    atlas_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.atlasParamType))
    map_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.mapParamType))
    #@show map_ParamType
    #@show atlas_ParamType
    weight_type=types[atlasHeader.weightType] #ensure weight type is defined
    
    #print("Reading atlasParam in openAtlas\n")
    buff=readline(io)
    atlasParam=JSON3.read(buff,atlas_ParamType)
    #print("atlasParam :",atlasParam," : ",typeof(atlasParam),"\n")
    
    #print("making atlas in openAtlas\n")
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

end # module AtlasIO
