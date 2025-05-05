using StructTypes, JSON3, Dates
using TranscodingStreams, CodecBzip2, CodecZlib
# import Base.close,Base.eof

export Map, 
    smartOpen,
    AtlasHeader,
    Atlas,
    Districting,
    newAtlas,
    openAtlas,
    nextMap,
    addMap,
    close,
    smartOpen,
    skipMap,
    eof,
    copyAtlisHeader,
    parseBufferToMap

struct AtlasHeader
    description::String
    date::String
    atlasParamType::String
    mapParamType::String
end
StructTypes.StructType(::Type{AtlasHeader}) = StructTypes.Struct()

AtlasHeader(name::String,date::String,atlasParamType::DataType,mapParamType::DataType)=AtlasHeader(name,date,string(atlasParamType),string(mapParamType))
AtlasHeader(name::String,atlasParamType::DataType,mapParamType::DataType)=AtlasHeader(name,string(now()),string(atlasParamType),string(mapParamType))
    
struct Atlas{T}
    io::IO
    description::String
    date::String
    atlasParam::T
    mapParamType::DataType
end
Atlas{T}(io::IO,atlasHeader::AtlasHeader,atlasParam::T) where T=Atlas(io,atlasHeader.description,atlasHeader.date,atlasParam,atlasHeader.mapParamType)

Districting=Dict{Tuple{Vararg{String}},Int64} #Dict{String,Int64}

Base.@kwdef struct Map{T} # T is the data type of the Data about them map. Dict must us string keys
    name::String
    districting::Districting
    weight::Int64=1
    data::T
end

function Map{T}(x::Dict{String, Any}) where T<:Any
    dict=Dict{Tuple{Vararg{String}}, Int64}()
    for x in x["districting"]
        for (k,v) in x
                kk=Tuple{Vararg{String}}(JSON3.read(k))
                dict[kk]=v
        end
    end
    return Map(x["name"],dict,Int(x["weight"]),T(x["data"]))
end
StructTypes.StructType(::Type{<:Map}) = StructTypes.CustomStruct()
StructTypes.lower(x::Map{T} where T) = (name=x.name, weight=x.weight, data=x.data, districting=[[ x for x in k] => v for (k, v) in x.districting])

function newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam)
    JSON3.write(io,"This is an Atlas for Redistricting Maps")
    write(io,"\n")
    JSON3.write(io,atlasHeader)
    write(io,"\n")
    JSON3.write(io,atlasParam)
    write(io,"\n")
end

function openAtlas(io::IO)::Atlas
    #print("Entering openAtlas\n")
    buff=readline(io) #throw away initial line
    
    buff=readline(io)
    atlasHeader=JSON3.read(buff,AtlasHeader)
    
     #print("Convert Params in openAtlas\n")
    atlas_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.atlasParamType))
    map_ParamType=Dict{String,Any}#eval(Meta.parse(atlasHeader.mapParamType))
    #@show map_ParamType
    #@show atlas_ParamType
    
    
    #print("Reading atlasParam in openAtlas\n")
    buff=readline(io)
    atlasParam=JSON3.read(buff,atlas_ParamType)
    #print("atlasParam :",atlasParam," : ",typeof(atlasParam),"\n")
    
    #print("making atlas in openAtlas\n")
    atlas=Atlas{map_ParamType}(io,atlasHeader.description,atlasHeader.date,atlasParam,map_ParamType)
    
    return atlas
end
    
function nextMap(atlas::Atlas)::Map
    buff=readline(atlas.io)
    map=JSON3.read(buff,Map{atlas.mapParamType})
    return map
end

function parseBufferToMap(atlas::Atlas,buff::String)::Map
    map=JSON3.read(buff,Map{atlas.mapParamType})
    return map
end
function nextMap(atlas::Atlas,ioIterator::Base.EachLine)::Map
    buff=first(ioIterator)
    map=JSON3.read(buff,Map{atlas.mapParamType})
    return map
end

function addMap(io::IO,map::Map{T}) where T
    buff=JSON3.write(map)
    write(io,buff)+write(io,"\n")
end

function addMap(io::IO,dist::Districting,name::String,w::Int64,mapParams)
   addMap(io,Map{typeof(mapParams)}(name,dist,w,mapParams))
end

function Base.close(atlas::Atlas)
    Base.close(atlas.io)
end

"""
opens an IO stream which is wraped in a compression pipe 
if the fileneame extension suggests it. Currently suports .gz and .bz2.
Defaults to regular concompressed writing/reading if not one of these extensions.
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

function eof(atlas::Atlas)::Bool
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

function copyAtlisHeader(sourceFilename::String, outFilename::String)
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