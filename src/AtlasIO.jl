module AtlasIO

using JSON, Dates
using TranscodingStreams, CodecBzip2, CodecZlib
using Downloads


export Map,
    MapData,
    smartOpen,
    AtlasHeader,
    AtlasFormatError,
    Atlas,
    Districting,
    newAtlas,
    openAtlas,
    nextMap,
    nextMaps,
    nextMapData,
    addMap,
    addMaps,
    close,
    smartOpen,
    skipMap,
    eof,
    copyAtlasHeader,
    parseBufferToMap,
    parseBufferToMapData,
    parseMapData,
    parseMap,
    mapJSON,
    mapBytes,
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
    weightType::String
end

AtlasHeader(name::String,date::String,atlasParamType::DataType,mapParamType::DataType; weightType::DataType=Int64)=AtlasHeader(name,date,string(atlasParamType),string(mapParamType),string(weightType))
AtlasHeader(name::String,atlasParamType::DataType,mapParamType::DataType; weightType::DataType=Int64)=AtlasHeader(name,string(now()),string(atlasParamType),string(mapParamType),string(weightType))
# Back-compat: pre-float_weights headers had no weightType; default it to Int64
AtlasHeader(name::String,date::String,atlasParamType::String,mapParamType::String; weightType::String="Int64")=AtlasHeader(name,date,atlasParamType,mapParamType,weightType)
    
"""
    Atlas{T}

An Atlas open for reading, as returned by [`openAtlas`](@ref): the stream positioned at the first map, the
header's `description` and `date`, the atlas parameters `atlasParam::T`, the map `data` type, the
`weightType`, and `formatVersion`, the format version the header declares (`"1"` or `"2"`).
"""
struct Atlas{T}
    io::IO
    description::String
    date::String
    atlasParam::T
    mapParamType::DataType
    weightType::DataType
    formatVersion::String
end
Atlas{T}(io::IO,atlasHeader::AtlasHeader,atlasParam::T) where T =Atlas(io,atlasHeader.description,atlasHeader.date,atlasParam,atlasHeader.mapParamType,atlasHeader.weightType)
# Back-compat: before AtlasIO 0.2.1 an Atlas had no formatVersion; such callers mean v1
Atlas(io::IO,description::String,date::String,atlasParam,mapParamType::DataType,weightType::DataType) =
    Atlas(io,description,date,atlasParam,mapParamType,weightType,"1")
# Back-compat: pre-float_weights callers passed 5 positional args (no weightType); default it to Int64
Atlas{T}(io::IO,description::String,date::String,atlasParam::T,mapParamType::DataType) where T =Atlas(io,description,date,atlasParam,mapParamType,Int64)

"The Atlas format versions this AtlasIO reads (see atlas_format.md). It writes v1."
const FORMAT_VERSIONS = ("1", "2")

Districting=Dict{Tuple{Vararg{String}},Int64} #Dict{String,Int64}

Base.@kwdef struct Map{T,W<: Real} # T is the data type of the Data about them map. Dict must us string keys
    name::String
    districting::Districting
    weight::W
    data::T
end

"""
    parseDistrictKey(s) -> Tuple{Vararg{String}}

Decode a v1 district-key string such as `["MECKLENBURG", "052"]` into `("MECKLENBURG", "052")`.

The fast path handles the escapes AtlasIO itself writes (`\\"` and `\\\\`). A key containing any other
JSON escape -- e.g. `\\u00e9`, as Python's `json.dumps` writes non-ASCII characters by default, or `\\t` --
is decoded by a full JSON parse instead (AtlasIO 0.1.x dropped the backslash and mis-decoded these).
"""
function parseDistrictKey(s::AbstractString)
    toks=String[]
    cu=codeunits(s)
    i=1; n=length(cu)
    @inbounds while i<=n
        if cu[i]==UInt8('"')
            i+=1
            buf=IOBuffer()
            while i<=n && cu[i]!=UInt8('"')
                if cu[i]==UInt8('\\') && i<n
                    i+=1
                    (cu[i]==UInt8('"') || cu[i]==UInt8('\\')) || return _parseDistrictKeyJSON(s)
                end
                write(buf,cu[i]); i+=1
            end
            push!(toks,String(take!(buf)))
        end
        i+=1
    end
    return Tuple(toks)
end

"Slow path of `parseDistrictKey`: decode the key string as a JSON array of strings."
_parseDistrictKeyJSON(s::AbstractString) = Tuple(String.(JSON.parse(s, Vector{String})))

"""
    Map{T,W}(x::Dict{String,Any})

Build a `Map` from a parsed map line, in either format: the district assignment is read from `x["districting"]`
(v1) or `x["assignment"]` (v2), whichever the line has.
"""
Map{T,W}(x::Dict{String, Any}) where {T<:Any, W<:Real} = _mapFromDict(x, T, W, nothing)

"""
Build a `Map` from parsed map line `x`. `version` is the format version the atlas header declares (`"1"`
or `"2"`), or `nothing` to accept either; a line in the other format raises an `AtlasFormatError`.
"""
function _mapFromDict(x::Dict{String,Any}, ::Type{T}, ::Type{W}, version) where {T,W<:Real}
    hasV1 = haskey(x, "districting")
    hasV2 = haskey(x, "assignment")
    which = hasV1 && hasV2 ? "both \"districting\" (v1) and \"assignment\" (v2)" :
            hasV1 ? "\"districting\" (v1)" : "\"assignment\" (v2)"
    (hasV1 || hasV2) ||
        throw(AtlasFormatError("map line has neither \"districting\" (v1) nor \"assignment\" (v2)$(_mapName(x))."))
    hasV1 && hasV2 && throw(AtlasFormatError("map line has $which$(_mapName(x))."))
    if version !== nothing && (version == "2") != hasV2
        throw(AtlasFormatError("map line has $which but the header declares formatVersion \"$version\"" *
                               "$(_mapName(x)); a file holds maps of one version only."))
    end
    dict = hasV2 ? _assignmentToDistricting(x["assignment"], x) : _districtingFromV1(x["districting"])
    return Map(x["name"],dict,W(x["weight"]),T(x["data"]))
end

_mapName(x) = (n = get(x, "name", nothing); n isa AbstractString ? " (map \"$n\")" : "")

function _districtingFromV1(entries)
    dict=Districting()
    for x in entries
        for (k,v) in x
                kk=parseDistrictKey(k)
                dict[kk]=v
        end
    end
    return dict
end

"""
Flatten a v2 `assignment` tree into a `Districting`: the path from the top of the tree to each leaf is that
region's key. Enforces the spec's rule 3: every value is an integer district or a non-empty object.
(Rule 1, no key a prefix of another, holds for any tree.)
"""
function _assignmentToDistricting(tree, x)
    tree isa AbstractDict ||
        throw(AtlasFormatError("\"assignment\" must be a JSON object, not $(_jsonKind(tree))$(_mapName(x))."))
    d = Districting()
    _addAssignment!(d, tree, String[], x)
    return d
end

function _addAssignment!(d::Districting, node::AbstractDict, path::Vector{String}, x)
    for (name, v) in node
        push!(path, name)
        if v isa Integer && !(v isa Bool)
            typemin(Int64) <= v <= typemax(Int64) ||
                throw(AtlasFormatError("district $v at key $(Tuple(path)) does not fit in an Int64$(_mapName(x))."))
            d[Tuple(path)] = v
        elseif v isa AbstractDict
            isempty(v) && throw(AtlasFormatError("empty branch at key $(Tuple(path)) in \"assignment\": a split " *
                                                 "region must have at least one sub-region$(_mapName(x))."))
            _addAssignment!(d, v, path, x)
        else
            throw(AtlasFormatError("the value at key $(Tuple(path)) in \"assignment\" is $(_jsonKind(v)); it must " *
                                   "be an integer district or an object of sub-regions$(_mapName(x))."))
        end
        pop!(path)
    end
    return d
end

_jsonKind(v) = v === nothing ? "null" : v isa Bool ? "a boolean" : v isa AbstractString ? "a string" :
               v isa Number ? "the non-integer number $v" : v isa AbstractVector ? "an array" :
               v isa AbstractDict ? "an object" : string(typeof(v))
# Back-compat: allow constructing a Map with only the data type parameter;
# the weight type W is inferred from the supplied weight (defaults to Int64-style ints).
Map{T}(; name, districting, weight, data) where T = Map{T,typeof(weight)}(name, districting, weight, data)
Map{T}(name, districting, weight, data) where T = Map{T,typeof(weight)}(name, districting, weight, data)

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

"""
    districtingJSON(d::Districting) -> JSON.JSONText

The v1 on-disk districting: a JSON array of single-key objects, `[{"[\\"k1\\", \\"k2\\"]":v}, ...]`.
It is rendered by hand because JSON.jl would write a `Vector{Pair}` as ONE object, not one object per entry.

Each key is written in a single pass that applies both escaping levels at once (the key-tuple string and
the JSON string around it). The output is byte-identical to `_districtingJSONReference`, which builds each
key with `districtKeyString` and then JSON-escapes it; a name containing a control character or DEL (which
JSON.jl writes as `\\uXXXX`) goes through that reference path.
"""
function districtingJSON(d::Districting)
    buf = IOBuffer(sizehint = 32 * length(d) + 2)
    write(buf, UInt8('['))
    first = true
    for (k, v) in d
        first ? (first = false) : write(buf, UInt8(','))
        write(buf, UInt8('{'))
        _writeDistrictKey!(buf, k) || JSON.json(buf, districtKeyString(k))
        write(buf, UInt8(':'))
        _writeSmallInt!(buf, v)
        write(buf, UInt8('}'))
    end
    write(buf, UInt8(']'))
    return JSON.JSONText(String(take!(buf)))
end

"""
Write district key `k` as the JSON string of its v1 key string, e.g. `("a\\"b", "c")` as
`"[\\"a\\\\\\"b\\", \\"c\\"]"`, in one pass. Returns `false`, having written nothing, if a name contains a
control character or DEL; the caller then uses the reference path.
"""
function _writeDistrictKey!(buf::IOBuffer, k)::Bool
    special = false                           # any '"' or '\\' (each needs a 4-byte escape)
    for s in k, c in codeunits(s)
        (c < 0x20 || c == 0x7f) && return false
        special |= (c == UInt8('"')) | (c == UInt8('\\'))
    end
    write(buf, UInt8('"'), UInt8('['))
    first = true
    for s in k
        first ? (first = false) : write(buf, UInt8(','), UInt8(' '))
        write(buf, UInt8('\\'), UInt8('"'))
        if special
            for c in codeunits(s)
                if c == UInt8('"')                 # inner \"  ->  JSON \\\"
                    write(buf, UInt8('\\'), UInt8('\\'), UInt8('\\'), UInt8('"'))
                elseif c == UInt8('\\')            # inner \\  ->  JSON \\\\
                    write(buf, UInt8('\\'), UInt8('\\'), UInt8('\\'), UInt8('\\'))
                else
                    write(buf, c)
                end
            end
        else
            write(buf, s)                          # common case: copy the name as-is
        end
        write(buf, UInt8('\\'), UInt8('"'))
    end
    write(buf, UInt8(']'), UInt8('"'))
    return true
end

"Write integer `v` in decimal; districts are small, so 0–999 skip `print`'s allocation."
@inline function _writeSmallInt!(buf::IOBuffer, v::Integer)
    if 0 <= v < 10
        write(buf, UInt8('0') + UInt8(v))
    elseif 10 <= v < 100
        write(buf, UInt8('0') + UInt8(div(v, 10)), UInt8('0') + UInt8(rem(v, 10)))
    elseif 100 <= v < 1000
        write(buf, UInt8('0') + UInt8(div(v, 100)), UInt8('0') + UInt8(rem(div(v, 10), 10)),
              UInt8('0') + UInt8(rem(v, 10)))
    else
        print(buf, v)
    end
    return nothing
end

"Reference (slower, two-pass) districting writer; `districtingJSON` must produce the same bytes."
function _districtingJSONReference(d::Districting)
    buf = IOBuffer()
    write(buf, '[')
    first = true
    for (k, v) in d
        first ? (first = false) : write(buf, ',')
        write(buf, '{')
        JSON.json(buf, districtKeyString(k))
        write(buf, ':')
        print(buf, v)
        write(buf, '}')
    end
    write(buf, ']')
    return JSON.JSONText(String(take!(buf)))
end

# Map's on-disk form (v1, the format AtlasIO writes): field order name, weight, data, districting (the lazy
# MapData reader relies on the assignment coming last).
JSON.lower(x::Map) = (name=x.name, weight=x.weight, data=x.data, districting=districtingJSON(x.districting))

"""
    AtlasStyle <: JSON.JSONStyle

AtlasIO's JSON settings. Writing goes through this style so that value types AtlasIO 0.1.x (JSON3) wrote
in a particular way keep that on-disk form, without changing how those types are written by JSON.jl for
everyone else (no type piracy).
"""
struct AtlasStyle <: JSON.JSONStyle end
JSON.lower(::AtlasStyle, x::Rational) = float(x)      # 0.1.x wrote 1//3 as 0.3333333333333333
# 0.1.x wrote a BigFloat with all its digits (string(x)); some JSON.jl versions write the shortest form.
JSON.lower(::AtlasStyle, x::BigFloat) = isfinite(x) ? JSON.JSONText(string(x)) : x
# 0.1.x wrote DateTime/Time with Dates' ISO formats, which always show the fraction ("…T01:02:03.0");
# JSON.jl's default drops a zero fraction ("…T01:02:03").
const _TIME_FORMAT = dateformat"HH:MM:SS.s"
JSON.lower(::AtlasStyle, x::DateTime) = Dates.format(x, Dates.ISODateTimeFormat)
JSON.lower(::AtlasStyle, x::Time) = Dates.format(x, _TIME_FORMAT)
# 0.1.x wrote arrays of 2+ dimensions flattened in column-major order ([1 2; 3 4] -> [1,3,2,4]);
# JSON.jl's default writes them nested.
JSON.lower(::AtlasStyle, x::AbstractArray) = vec(x)
# Vectors keep JSON.jl's own handling (this method only resolves the dispatch ambiguity with JSON's).
JSON.lower(st::AtlasStyle, x::AbstractVector) = invoke(JSON.lower, Tuple{JSON.JSONStyle, AbstractVector}, st, x)

const ATLAS_STYLE = AtlasStyle()

# All JSON output goes through these. `sort_keys=false` keeps Dict keys in iteration order, as 0.1.x did
# (JSON.jl sorts plain Dict keys by default).
_json(x) = JSON.json(x; style=ATLAS_STYLE, sort_keys=false)
_json(io::IO, x) = JSON.json(io, x; style=ATLAS_STYLE, sort_keys=false)

# All JSON input goes through this: every object becomes a Dict{String,Any} at every level (JSON.jl's
# default is its order-preserving JSON.Object), every array a Vector{Any}, and numbers keep their type
# exactly (0.0 stays Float64, integers beyond 2^53 stay exact).
_parse(s) = JSON.parse(s; dicttype=Dict{String,Any})

function newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam)
    _json(io,"This is an Atlas for Redistricting Maps. See 'https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md' for more information about the format.")
    write(io,"\n")
    _json(io,atlasHeader)
    write(io,"\n")
    _json(io,atlasParam)
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

"Read a line from `io`, wrapping any stream-level failure (e.g. a truncated or
CRC-corrupt `.gz`/`.bz2` file) as an `AtlasFormatError` naming `what`, so callers get
a consistent, readable message instead of a raw decompressor exception."
function _readlineOrFormatError(io::IO, what::String)
    try
        return readline(io)
    catch e
        throw(AtlasFormatError("not a valid Atlas file: failed to read $what " *
                               "(the underlying stream raised an error, possibly a " *
                               "truncated or corrupt compressed file) ($(sprint(showerror, e)))."))
    end
end

function openAtlas(io::IO)::Atlas
    _readlineOrFormatError(io, "the initial banner line (line 1)") #throw away initial line (the human-readable format banner)

    headerLine = _readlineOrFormatError(io, "the header line (line 2)")
    local headerAny
    try
        headerAny = _parse(headerLine)
        headerAny isa Dict{String,Any} || error("it is not a JSON object")
    catch e
        throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) " *
                               "did not parse as JSON ($(sprint(showerror, e)))."))
    end
    for (k, v) in headerAny
        v isa String || throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) value of " *
                                               "\"$k\" must be a JSON string, not $(_jsonKind(v))."))
    end
    atlasHeaderDict = Dict{String,String}(headerAny)

    formatVersion = get(atlasHeaderDict, "formatVersion", "1")
    formatVersion in FORMAT_VERSIONS ||
        throw(AtlasFormatError("unsupported Atlas formatVersion \"$formatVersion\": AtlasIO " *
                               "$(pkgversion(@__MODULE__)) reads format versions $(join(FORMAT_VERSIONS, " and ")). " *
                               "Upgrade AtlasIO to read this file."))

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

    paramLine = _readlineOrFormatError(io, "the atlas-parameters line (line 3)")
    local atlasParam
    try
        atlasParam = atlas_ParamType(_parse(paramLine))
    catch e
        throw(AtlasFormatError("not a valid Atlas file: the atlas-parameters line " *
                               "(line 3) did not parse as JSON ($(sprint(showerror, e)))."))
    end

    atlas=Atlas{map_ParamType}(io,atlasHeader.description,atlasHeader.date,atlasParam,map_ParamType, weight_type, formatVersion)

    return atlas
end
    
"""
    parseMap(line, T, W=Int64) -> Map{T,W}

Parse one Atlas map line (the JSON text of a single map, with or without its trailing newline) into a
`Map{T,W}`: `T` is the type of the map's `data`, `W` the weight type. Any JSON or decoding failure is
raised as an [`AtlasFormatError`](@ref).

The line may be in either format version: its district assignment is read from `districting` (v1) or
`assignment` (v2), whichever it has. Reading through an open `Atlas` (`nextMap`, `nextMaps`,
[`parseBufferToMap`](@ref)) also checks that each line matches the version its header declares.

This is the way to parse map lines you have read yourself (e.g. to parse them in parallel), without
needing any JSON library: use it instead of `JSON3.read(line, Map{T,W})`, which no longer works since
AtlasIO 0.2. [`parseBufferToMap`](@ref) does the same with the types taken from an open `Atlas`.
"""
parseMap(line::AbstractString, ::Type{T}, ::Type{W}=Int64) where {T, W<:Real} = _parseMap(line, T, W, nothing)

function _parseMap(line::AbstractString, ::Type{T}, ::Type{W}, version) where {T, W<:Real}
    local x
    try
        x = _parse(line)
        x isa Dict{String,Any} || error("a map line must be a JSON object")
    catch e
        throw(AtlasFormatError("not a valid Atlas map line: failed to parse as JSON " *
                               "($(sprint(showerror, e)))."))
    end
    try
        return _mapFromDict(x, T, W, version)
    catch e
        e isa AtlasFormatError && rethrow()
        throw(AtlasFormatError("not a valid Atlas map line$(_mapName(x)): $(sprint(showerror, e))."))
    end
end

"Parse `buff` as a `Map` line of `atlas`, raising any failure as an `AtlasFormatError`."
_parseMapLine(atlas::Atlas, buff::AbstractString)::Map =
    _parseMap(buff, atlas.mapParamType, atlas.weightType, atlas.formatVersion)

function nextMap(atlas::Atlas)::Map
    eof(atlas.io) && throw(EOFError())
    buff = try
        readline(atlas.io)
    catch e
        throw(AtlasFormatError("failed to read a map line: the underlying stream raised " *
                               "an error (possibly a truncated or corrupt compressed file) " *
                               "($(sprint(showerror, e)))."))
    end
    return _parseMapLine(atlas, buff)
end

function parseBufferToMap(atlas::Atlas,buff::String)::Map
    return _parseMapLine(atlas, buff)
end
function nextMap(atlas::Atlas,ioIterator::Base.EachLine)::Map
    buff = try
        first(ioIterator)
    catch e
        e isa ArgumentError ? throw(EOFError()) : rethrow()
    end
    return _parseMapLine(atlas, buff)
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
        try
            Threads.@threads for i in 1:nread
                @inbounds out[base + i] = parseBufferToMap(atlas, lines[i])
            end
        catch e
            # Raise a bad line's error itself (as nextMap does), not the threads' CompositeException.
            try wait(pending) catch end   # let the prefetch finish before handing the stream back
            throw(_firstTaskError(e))
        end
    end
    return out
end

"The exception a failed `Threads.@threads` loop raised in its first failed task (or `e` itself)."
function _firstTaskError(e)
    while true
        if e isa CompositeException && !isempty(e.exceptions)
            e = first(e.exceptions)
        elseif e isa TaskFailedException
            e = e.task.exception
        else
            return e
        end
    end
end

"""
    MapData{T,W<:Real}

Like [`Map`](@ref) but without `districting`: just `name`, `weight`, and `data`.
Produced by [`parseMapData`](@ref)/[`nextMapData`](@ref)/[`parseBufferToMapData`](@ref)
for callers that only need a map's data fields. Parsing a full `Map` pays to
reconstruct `districting` (one key-tuple per graph node -- by far the most
expensive part of the parse) even when the caller never looks at it; `MapData`
skips that work entirely. There is no field to accidentally misuse in its place --
unlike, say, a `Map` given an empty placeholder `districting`.
"""
struct MapData{T,W<:Real}
    name::String
    weight::W
    data::T
end

"""
    parseMapData(buff, T, W=Int64) -> MapData{T,W}

Parse a map line `buff` into a [`MapData`](@ref): only `name`, `weight`, and
`data` are touched. The district assignment is never materialized, nor even scanned: the line
is read with JSON.jl's lazy parser, and the assignment (`districting` in v1, `assignment` in v2) is the last
field of a map line, so the three lookups stop before reaching it. This works the same for both format
versions. Wraps a parse failure as an
`AtlasFormatError`, matching [`parseMap`](@ref).

`data` is converted exactly as [`parseMap`](@ref) does, `T(data)` with objects as
`Dict{String,Any}` and arrays as `Vector{Any}` at every level, so a `MapData` and
a `Map` parsed from the same line hold equal data. `T` need not be a `Dict`, and
`data` need not be a JSON object.
"""
function parseMapData(buff::AbstractString, ::Type{T}, ::Type{W}=Int64) where {T,W<:Real}
    try
        obj = JSON.lazy(buff)
        dataVal = T(_parse(obj.data))
        return MapData{T,W}(String(obj.name[]), W(obj.weight[]), dataVal)
    catch e
        throw(AtlasFormatError("not a valid Atlas map line: failed to parse as JSON " *
                               "($(sprint(showerror, e)))."))
    end
end

"""
    nextMapData(atlas::Atlas) -> MapData

Like [`nextMap`](@ref) but returns a [`MapData`](@ref) -- `districting` is not
parsed. Composes with `skipMap`/`nextMap` the same way `nextMap` does (reads
from wherever `atlas` is currently positioned).
"""
function nextMapData(atlas::Atlas)::MapData
    eof(atlas.io) && throw(EOFError())
    buff = try
        readline(atlas.io)
    catch e
        throw(AtlasFormatError("failed to read a map line: the underlying stream raised " *
                               "an error (possibly a truncated or corrupt compressed file) " *
                               "($(sprint(showerror, e)))."))
    end
    return parseMapData(buff, atlas.mapParamType, atlas.weightType)
end

"""
    parseBufferToMapData(atlas::Atlas, buff::String) -> MapData

Like [`parseBufferToMap`](@ref) but returns a [`MapData`](@ref) -- `districting`
is not parsed. Intended for the same batched/threaded use: read lines serially,
parse each with this in parallel.
"""
function parseBufferToMapData(atlas::Atlas, buff::String)::MapData
    return parseMapData(buff, atlas.mapParamType, atlas.weightType)
end

"""
    mapJSON(m::Map) -> String

The JSON text of map `m` exactly as it appears on one line of an Atlas file, WITHOUT the trailing
newline. Use [`mapBytes`](@ref) for a complete line ready to write.
"""
mapJSON(m::Map) = _json(m)

"""
    mapBytes(m::Map) -> Vector{UInt8}

One complete Atlas map line for `m`, INCLUDING the trailing `"\\n"`: exactly the bytes `addMap` writes.
Use it to build the input of [`writeMaps!`](@ref), e.g. `writeMaps!(out, mapBytes.(maps))`.
"""
function mapBytes(m::Map)
    io = IOBuffer()
    _json(io, m)
    write(io, '\n')
    return take!(io)
end

function addMap(io::IO,map::Map{T}) where T
    write(io, mapBytes(map))
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
    lines = Vector{Vector{UInt8}}(undef, length(ms))
    Threads.@threads for i in eachindex(ms)
        @inbounds lines[i] = mapBytes(ms[i])
    end
    nb = 0
    @inbounds for i in eachindex(ms)
        nb += write(io, lines[i])
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

`fileName` may also be an `http://` or `https://` URL, in which case only
`io_mode=="r"` is supported. By default the URL is streamed and decompressed
on the fly, without ever writing the whole file to disk. Pass `download=true`
to instead download the whole resource to a temporary file first (as earlier
versions did).
"""
function smartOpen(fileName::String, io_mode::String; download::Bool=false)::Union{IO,Nothing}
    _isURL(fileName) && return _smartOpenURL(fileName, io_mode; download=download)

    ext,base=getFileExtension(fileName)

    if ((io_mode=="w") |(io_mode=="a"))

        oo= try open(fileName,io_mode) #try to open filename given
        catch err
            _isMissingFileError(err) || rethrow()
            @info( string("Error opening file. Trying alternative extensions for ",fileName));
            if ((ext==".gz") | (ext==".bz2"))
                fileName=base;
                ext,base=getFileExtension(base);
                open(fileName,io_mode) #if first open fails and was compressed, try not compressed
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
                _isMissingFileError(err) || rethrow()
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
        eof(atlas.io) && throw(EOFError())
        readline(atlas.io)
        count+=1
    end
end


"True if `err` indicates the target path simply doesn't exist (ENOENT) -- the only
case where retrying `smartOpen` with an alternate compression extension makes sense.
Any other error (permission denied, missing directory, disk full, ...) is a real
failure and should propagate as-is rather than being masked by a second, unrelated
open attempt."
_isMissingFileError(err) = err isa SystemError && err.errnum == Base.Libc.ENOENT

_isURL(s::AbstractString) = startswith(s, "http://") || startswith(s, "https://")

"True if `err` indicates the remote resource simply doesn't exist (HTTP 404) --
the only case where retrying `smartOpen` with an alternate compression extension
makes sense for a URL."
_isMissingURLError(err) = err isa Downloads.RequestError && err.response.status == 404

"HEAD-requests `url`, returning its `Response`. On a connection-level failure --
one that never got far enough to receive an HTTP status -- `Downloads.request`
itself returns (rather than throws) a `RequestError` when `throw=false`; on a
failure it doesn't even return normally from (e.g. a lower-level exception),
`nothing` is returned instead. Either failure case is left for the real GET in
`_streamURL` to surface as a proper error."
function _headResponse(url::String)
    try
        return Downloads.request(url; method="HEAD", throw=false)
    catch
        return nothing
    end
end

"True if `resp` (from `_headResponse`) confirms the URL doesn't exist (HTTP 404).
`resp` may be a `Response`, a `RequestError` (a connection-level failure that
never reached HTTP semantics -- no `.status` to check, so not a confirmed 404),
or `nothing`; only a real `Response` can confirm a 404."
_isMissingResponse(resp) = resp isa Downloads.Response && resp.status == 404

"Strip a URL's query string and fragment so `getFileExtension` sees only the path."
function _urlExtension(url::AbstractString)
    p = first(split(url, '#'; limit=2))
    p = first(split(p, '?'; limit=2))
    return getFileExtension(String(p))[1]
end

"Swap a URL's compression extension: drop `.gz`/`.bz2` if present, else append `.gz`."
function _alternateURL(url::String, ext::String)
    if ext == ".gz" || ext == ".bz2"
        base = url[1:end-length(ext)]
        return base, _urlExtension(base)
    else
        return string(url, ".gz"), ".gz"
    end
end

function _smartOpenURL(url::String, io_mode::String; download::Bool=false)::Union{IO,Nothing}
    io_mode == "r" || throw(ArgumentError(
        "smartOpen only supports io_mode=\"r\" for URLs (got \"$io_mode\") for $url"))

    ext = _urlExtension(url)

    stream, ext = if download
        # `Downloads.download` only returns/throws once the whole transfer is
        # done, so it's safe to catch a real 404 afterwards and retry.
        try
            (_downloadURL(url), ext)
        catch err
            _isMissingURLError(err) || rethrow()
            @info(string("Error fetching URL. Trying alternative extensions for ", url))
            altURL, altExt = _alternateURL(url, ext)
            (_downloadURL(altURL), altExt)
        end
    else
        # Streaming forwards bytes to the caller as they arrive, often *before*
        # `Downloads.download` raises on a non-2xx status (many servers send an
        # error-page body first) -- too late to fall back cleanly. So check
        # existence with a cheap HEAD request first instead. `request` (unlike
        # `download`) never throws on a plain non-2xx status, so a genuine
        # double-miss is raised explicitly below.
        if _isMissingResponse(_headResponse(url))
            @info(string("Error fetching URL. Trying alternative extensions for ", url))
            url, ext = _alternateURL(url, ext)
            altResp = _headResponse(url)
            if _isMissingResponse(altResp)
                throw(Downloads.RequestError(url, Downloads.Curl.CURLE_OK, "", altResp))
            end
        end
        (_streamURL(url), ext)
    end

    ext == ".bz2" && return Bzip2DecompressorStream(stream)
    ext == ".gz" && return GzipDecompressorStream(stream)
    return stream
end

"Downloads the whole URL to a temporary file, then opens (and unlinks) it."
function _downloadURL(url::String)::IO
    tmpPath = Downloads.download(url, tempname())
    oo = open(tmpPath, "r")
    try
        rm(tmpPath; force=true)   # unlink now; the open fd keeps the data readable on Unix
    catch
        # e.g. Windows can't remove an open file -- leave it for OS temp cleanup
    end
    return oo
end

"""
A readable `IO` fed by a background task streaming `Downloads.download`
straight into a `Base.BufferStream`, so bytes are available to read (and
decompress) as they arrive instead of waiting for the whole transfer.
"""
struct URLStream <: IO
    buf::Base.BufferStream
    task::Task
end

Base.isopen(s::URLStream) = isopen(s.buf)
Base.bytesavailable(s::URLStream) = bytesavailable(s.buf)
Base.readavailable(s::URLStream) = readavailable(s.buf)
Base.unsafe_read(s::URLStream, p::Ptr{UInt8}, n::UInt) = unsafe_read(s.buf, p, n)
Base.read(s::URLStream, ::Type{UInt8}) = read(s.buf, UInt8)

"`eof` also surfaces any error the download task raised (e.g. a 404), once
the buffer has caught up to it, by re-throwing the task's original exception."
function Base.eof(s::URLStream)
    isEOF = eof(s.buf)
    isEOF && _waitRethrow(s.task)
    return isEOF
end

function Base.close(s::URLStream)
    close(s.buf)
    try
        _waitRethrow(s.task)
    catch
        # already surfaced to the reader via eof/read; don't re-raise on close
    end
end

function _waitRethrow(task::Task)
    try
        wait(task)
    catch err
        err isa TaskFailedException ? rethrow(err.task.exception) : rethrow(err)
    end
end

"Streams the URL into a `URLStream`, blocking only until the first bytes
arrive (or the request fails/completes empty) so failures like a 404
surface immediately without waiting for the full transfer."
function _streamURL(url::String)::URLStream
    buf = Base.BufferStream()
    task = @async try
        Downloads.download(url, buf)
    finally
        close(buf)
    end
    stream = URLStream(buf, task)
    eof(stream)
    return stream
end

function getFileExtension(filename::String)
    i=findlast(isequal('.'),filename)
    i === nothing && return "", filename   # no '.' in filename -> no extension
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
