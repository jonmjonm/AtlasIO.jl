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
    convertAtlas,
    GZIP_MEMBER_TARGET

"""
    AtlasHeader(description, atlasParamType, mapParamType; weightType = Int64)
    AtlasHeader(description, date, atlasParamType, mapParamType; weightType = Int64)

The header (line 2) of an Atlas file, for writing one with [`newAtlas`](@ref): a `description`, the `date`
(now, if not given), the types of the atlas parameters and of each map's `data` (usually
`Dict{String,Any}`), and `weightType`, the type of the maps' weights: `Int64` or `Float64`. The types are
stored by name, so the strings themselves are accepted too. Reading an atlas with [`openAtlas`](@ref) gives
the same fields on the `Atlas`.

```julia
header = AtlasHeader("NC congressional ensemble", Dict{String,Any}, Dict{String,Any}; weightType = Float64)
```
"""
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

"v1 districting with its entries in sorted key order (deterministic; used by `convertAtlas`)."
function _districtingJSONSorted(d::Districting)
    buf = IOBuffer(sizehint = 32 * length(d) + 2)
    write(buf, UInt8('['))
    first = true
    for k in sort!(collect(keys(d)); lt=_keyless)
        first ? (first = false) : write(buf, UInt8(','))
        write(buf, UInt8('{'))
        _writeDistrictKey!(buf, k) || JSON.json(buf, districtKeyString(k))
        write(buf, UInt8(':'))
        _writeSmallInt!(buf, d[k])
        write(buf, UInt8('}'))
    end
    write(buf, UInt8(']'))
    return JSON.JSONText(String(take!(buf)))
end

"""
    _assignmentJSON(d::Districting, name="") -> JSON.JSONText

The v2 on-disk assignment (atlas_format.md, "v2: assignment"): a tree whose names are sorted at every level
(by code point, the UTF-8 byte order the spec asks for), so the same districting always gives the same bytes.

The keys are first grouped into a tree of Dicts, one level per region level, and each level's names are then
sorted as plain strings. (Sorting the keys themselves is slow: they are tuples of varying length.) Building
the tree also finds every districting v2 cannot hold, raising an `AtlasFormatError` naming map `name`: an
empty key `()`, or a key that is a prefix of another (rule 1: a region is assigned whole or split, never both).
"""
function _assignmentJSON(d::Districting, name::AbstractString="")
    root = Dict{String,Any}()
    for (k, v) in d
        n = length(k)
        n == 0 && throw(AtlasFormatError("cannot write format v2: $(_forMap(name))the district key () is " *
                                         "empty; a v2 key names at least one region."))
        node = root
        for i in 1:(n - 1)
            child = get!(Dict{String,Any}, node, k[i])
            child isa Dict{String,Any} || _prefixError(name, k[1:i], k)
            node = child
        end
        haskey(node, k[n]) && _prefixError(name, k, _someKeyUnder(k, node[k[n]]))
        node[k[n]] = v
    end
    buf = IOBuffer(sizehint = 16 * length(d) + 2)
    _writeAssignmentNode!(buf, root)
    return JSON.JSONText(String(take!(buf)))
end

function _writeAssignmentNode!(buf::IOBuffer, node::Dict{String,Any})
    write(buf, UInt8('{'))
    first = true
    for name in sort!(collect(keys(node)))
        first ? (first = false) : write(buf, UInt8(','))
        _writeJSONName!(buf, name)
        write(buf, UInt8(':'))
        v = node[name]
        v isa Dict{String,Any} ? _writeAssignmentNode!(buf, v) : _writeSmallInt!(buf, v::Int64)
    end
    write(buf, UInt8('}'))
    return nothing
end

"A key in the subtree `node` found under `prefix` (for the error message)."
_someKeyUnder(prefix, node) = node isa Dict{String,Any} ?
    (n = first(sort!(collect(keys(node)))); _someKeyUnder((prefix..., n), node[n])) : prefix

_prefixError(name, short, long) =
    throw(AtlasFormatError("cannot write format v2: $(_forMap(name))the key $(Tuple(short)) is a prefix of the key " *
                           "$(Tuple(long)), so the region would be both whole and split (rule 1 of " *
                           "atlas_format.md). Write v1 or fix the districting."))

"Key order: element by element (code point order), a key before the keys it is a prefix of."
function _keyless(a::Tuple{Vararg{String}}, b::Tuple{Vararg{String}})
    for i in 1:min(length(a), length(b))
        x, y = a[i]::String, b[i]::String
        x == y || return isless(x, y)
    end
    return length(a) < length(b)
end

"Write `s` as a JSON string: directly when nothing needs escaping, else through JSON.jl."
function _writeJSONName!(buf::IOBuffer, s::String)
    for c in codeunits(s)
        if c < 0x20 || c == 0x7f || c == UInt8('"') || c == UInt8('\\')
            JSON.json(buf, s)
            return nothing
        end
    end
    write(buf, UInt8('"'), s, UInt8('"'))
    return nothing
end

_forMap(name) = isempty(name) ? "" : "map \"$name\": "

"""
Normalize a format version given as `1`, `2`, `"1"` or `"2"` to the header's string form. Anything else is an
`ArgumentError`.
"""
function _formatVersion(v)
    s = v isa AbstractString ? String(v) : v isa Integer ? string(v) : ""
    s in FORMAT_VERSIONS ||
        throw(ArgumentError("formatVersion must be 1 or 2 (or \"1\" or \"2\"), got $(repr(v))"))
    return s
end

# Map's on-disk form: field order name, weight, data, then the assignment (the lazy MapData reader relies on
# the assignment coming last). This is v1; `_mapForm(m, "2")` gives v2.
JSON.lower(x::Map) = (name=x.name, weight=x.weight, data=x.data, districting=districtingJSON(x.districting))

_mapForm(m::Map, version::String) = version == "1" ? m :
    (name=m.name, weight=m.weight, data=m.data, assignment=_assignmentJSON(m.districting, m.name))

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

"""
    newAtlas(io, atlasHeader, atlasParam; formatVersion=1)

Write an Atlas's three header lines to `io`: the banner, `atlasHeader`, and the atlas parameters. Then write
each map with [`addMap`](@ref)/[`addMaps`](@ref) (or [`mapBytes`](@ref)) using the SAME `formatVersion`.

`formatVersion` is `1` (the default) or `2` (see atlas_format.md). For v2 the header gains
`"formatVersion":"2"`; v1 output is exactly what earlier versions of AtlasIO wrote. A file whose maps are not
in its header's version is rejected by every reader.
"""
function newAtlas(io::IO, atlasHeader::AtlasHeader, atlasParam; formatVersion=1)
    version = _formatVersion(formatVersion)
    _json(io,"This is an Atlas for Redistricting Maps. See 'https://github.com/jonmjonm/AtlasIO.jl/blob/main/atlas_format.md' for more information about the format.")
    write(io,"\n")
    if version == "1"
        _json(io,atlasHeader)
    else
        h = atlasHeader
        _json(io, (description=h.description, date=h.date, atlasParamType=h.atlasParamType,
                   mapParamType=h.mapParamType, weightType=h.weightType, formatVersion=version))
    end
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

"""
    openAtlas(io::IO) -> Atlas

Read the three header lines of an Atlas file from `io` (usually from [`smartOpen`](@ref), which handles
`.gz`/`.bz2` and URLs) and return an `Atlas` positioned at the first map: its `description`, `date`,
`atlasParam` (the line-3 parameters), `mapParamType`, `weightType` (`Int64` unless the header says `Float64`)
and `formatVersion` (`"1"` or `"2"`). Read the maps with [`nextMap`](@ref) (or `nextMaps`,
[`skipMap`](@ref)) until `eof(atlas)`, then `close(atlas)`, which closes `io`.

A file that isn't a valid Atlas (an unparsable or incomplete header, an unknown `weightType`, a format version
this AtlasIO can't read) raises an [`AtlasFormatError`](@ref) saying what is wrong.

```julia
atlas = openAtlas(smartOpen("atlas.jsonl.gz", "r"))
while !eof(atlas)
    m = nextMap(atlas)
end
close(atlas)
```
"""
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

"""
    nextMap(atlas::Atlas) -> Map
    nextMap(atlas::Atlas, lines::Base.EachLine) -> Map

Read and parse the next map of `atlas`: a `Map` with its `name`, `districting`, `weight` (of the atlas's
`weightType`) and `data`. Call it while `!eof(atlas)`; past the last map it throws an `EOFError`. A map line
that doesn't parse, or isn't in the format version the header declares, raises an
[`AtlasFormatError`](@ref) naming the map when it can.

The second form takes the line from `lines`, an `eachline(atlas.io)` iterator the caller holds. For many maps
at once, `nextMaps` parses in parallel.
"""
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

"""
    parseBufferToMap(atlas::Atlas, line::String) -> Map

Parse `line`, one map line of `atlas` that you read yourself, into a `Map` with the atlas's data and weight
types, checking it is in the format version the header declares. Like [`parseMap`](@ref) with the types taken
from `atlas`; errors are raised as an [`AtlasFormatError`](@ref).
"""
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
    mapJSON(m::Map; formatVersion=1) -> String

The JSON text of map `m` exactly as it appears on one line of an Atlas file, WITHOUT the trailing
newline. Use [`mapBytes`](@ref) for a complete line ready to write. With `formatVersion=2` the assignment is
written as a v2 tree (`"assignment"`), which raises an `AtlasFormatError` if a key is empty or is a prefix
of another key.
"""
mapJSON(m::Map; formatVersion=1) = _json(_mapForm(m, _formatVersion(formatVersion)))

"""
    mapBytes(m::Map; formatVersion=1) -> Vector{UInt8}

One complete Atlas map line for `m`, INCLUDING the trailing `"\\n"`: exactly the bytes `addMap` writes.
Use it to build the input of [`writeMaps!`](@ref), e.g. `writeMaps!(out, mapBytes.(maps))`. See
[`mapJSON`](@ref) for `formatVersion`.
"""
function mapBytes(m::Map; formatVersion=1)
    io = IOBuffer()
    _json(io, _mapForm(m, _formatVersion(formatVersion)))
    write(io, '\n')
    return take!(io)
end

"""
    addMap(io, map; formatVersion=1)
    addMap(io, districting, name, weight, data; formatVersion=1)

Write one map line to `io`, in the format version the atlas was started with ([`newAtlas`](@ref)).
"""
function addMap(io::IO,map::Map{T}; formatVersion=1) where T
    write(io, mapBytes(map; formatVersion=formatVersion))
end

function addMap(io::IO,dist::Districting,name::String,w::Real,mapParams; formatVersion=1)
   addMap(io,Map{typeof(mapParams)}(name,dist,w,mapParams); formatVersion=formatVersion)
end

"""
    addMaps(io::IO, maps; formatVersion=1) -> Int

Write a collection of `Map`s to `io`. JSON serialization (the bottleneck on the
write path) is done in parallel across threads, then the resulting strings are
written to `io` serially in order. The output is byte-identical to calling
`addMap(io, m; formatVersion)` for each map in turn. Returns the total number of bytes written.

Start Julia with multiple threads (e.g. `julia -t auto`) to benefit; with a
single thread it runs serially with negligible overhead.
"""
function addMaps(io::IO, maps; formatVersion=1)
    version = _formatVersion(formatVersion)
    ms = collect(maps)                       # ensure 1-based, indexable
    lines = Vector{Vector{UInt8}}(undef, length(ms))
    try
        Threads.@threads for i in eachindex(ms)
            @inbounds lines[i] = mapBytes(ms[i]; formatVersion=version)
        end
    catch e
        throw(_firstTaskError(e))            # e.g. a map v2 cannot hold, as addMap would raise it
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

"""
    skipMap(atlas::Atlas; numSkip = 1)

Skip the next `numSkip` maps of `atlas` without parsing them (e.g. a burn-in). Throws an `EOFError` if the
atlas runs out first; the maps before that are still skipped.
"""
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

"""
    copyAtlasHeader(sourceFilename, outFilename)

Write a new file `outFilename` holding only the three header lines of the atlas `sourceFilename`, copied byte
for byte (compression for each file by its extension, as in [`smartOpen`](@ref)). Both files are closed
afterwards. `outFilename` is overwritten if it exists.
"""
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

# ---------------------------------------------------------------------------
# Converting between format versions
# ---------------------------------------------------------------------------

"""
    convertAtlas(src, dst; formatVersion, batch=1024, cores=Threads.nthreads()) -> Int

Copy the Atlas file `src` to `dst`, converting every map to format version `formatVersion` (`1` or `2`; see
atlas_format.md), and return the number of maps. Either file may be plain, `.gz` or `.bz2` (by extension).

Only what the version changes is rewritten: the header's `formatVersion` (added for v2, removed for v1) and
each map's assignment field (`districting` in v1, `assignment` in v2). The banner, the atlas parameters, and
each map's name, weight and data are copied byte for byte, so no data value or its formatting can change.
v2 trees are written sorted; v1 entries are written in sorted key order. Every line, the last included, ends
with a newline. Converting is lossless: converting back gives the same districting for every map.

Raises an `AtlasFormatError` naming the line and map for anything that cannot be converted: a map line that
does not match the header's version, a districting v2 cannot hold (a key that is a prefix of another, or an
empty key), or a map line whose assignment is not its last field. `dst` is then removed.
Map lines are converted in parallel across threads in batches of `batch` lines; a `.gz` `dst` is written as
parallel gzip members (see [`AtlasOutput`](@ref)).
"""
function convertAtlas(src::AbstractString, dst::AbstractString; formatVersion, batch::Integer=1024,
                      cores::Int=Threads.nthreads())
    to = _formatVersion(formatVersion)
    batch >= 1 || throw(ArgumentError("batch must be ≥ 1"))
    abspath(src) == abspath(dst) && throw(ArgumentError("convertAtlas: src and dst are the same file: $src"))
    isfile(src) || throw(ArgumentError("convertAtlas: no such file: $src"))
    in = smartOpen(String(src), "r")
    out = nothing
    try
        banner = _readlineOrFormatError(in, "the initial banner line (line 1)")
        headerLine = _readlineOrFormatError(in, "the header line (line 2)")
        paramLine = _readlineOrFormatError(in, "the atlas-parameters line (line 3)")
        from, newHeader = _convertHeader(headerLine, to)
        out = openAtlasOutput(String(dst), Vector{UInt8}(banner * "\n" * newHeader * "\n" * paramLine * "\n"),
                              cores)
        n = 0
        lines = String[]
        while true
            empty!(lines)
            while length(lines) < batch && !eof(in)
                push!(lines, _readlineOrFormatError(in, "map line $(n + length(lines) + 4)"))
            end
            isempty(lines) && break
            bytes = Vector{Vector{UInt8}}(undef, length(lines))
            try
                Threads.@threads for i in eachindex(lines)
                    @inbounds bytes[i] = _convertMapLine(lines[i], from, to, n + i + 3)
                end
            catch e
                throw(_firstTaskError(e))
            end
            writeMaps!(out, bytes)
            n += length(lines)
        end
        close(out)
        out = nothing
        return n
    catch
        if out !== nothing
            try close(out) catch end
            rm(dst; force=true)
        end
        rethrow()
    finally
        close(in)
    end
end

"""
The header line converted to format version `to`, and the version it declared: `(from, line)`. The line is
returned unchanged when the version does not change; otherwise it is re-written with its fields in the same
order, `formatVersion` set (v2) or removed (v1).
"""
function _convertHeader(headerLine::AbstractString, to::String)
    local h
    try
        h = JSON.parse(headerLine)                       # JSON.Object: keeps the field order
        h isa AbstractDict || error("it is not a JSON object")
    catch e
        throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) did not parse as JSON " *
                               "($(sprint(showerror, e)))."))
    end
    for (k, v) in h
        v isa AbstractString || throw(AtlasFormatError("not a valid Atlas file: the header line (line 2) " *
                                                       "value of \"$k\" must be a JSON string, not $(_jsonKind(v))."))
    end
    from = String(get(h, "formatVersion", "1"))
    from in FORMAT_VERSIONS ||
        throw(AtlasFormatError("unsupported Atlas formatVersion \"$from\": AtlasIO $(pkgversion(@__MODULE__)) " *
                               "reads format versions $(join(FORMAT_VERSIONS, " and ")). Upgrade AtlasIO."))
    from == to && return from, String(headerLine)
    had = haskey(h, "formatVersion")
    to == "1" ? delete!(h, "formatVersion") : (h["formatVersion"] = to)
    # Edit just that field in the original text, so the rest of the header keeps its exact bytes; keep the
    # edit only if it parses to exactly the intended header (same fields, values and order).
    edited = _editHeaderVersion(String(headerLine), had, to)
    if edited !== nothing
        p = try JSON.parse(edited) catch; nothing end
        p isa AbstractDict && collect(keys(p)) == collect(keys(h)) && all(p[k] == h[k] for k in keys(h)) &&
            return from, edited
    end
    return from, JSON.json(h; sort_keys=false)
end

"The header text with its `formatVersion` field set to `to` (v2) or removed (v1), or `nothing`."
function _editHeaderVersion(line::String, had::Bool, to::String)
    field = r"\"formatVersion\"\s*:\s*\"[^\"\\]*\""
    if to == "2"
        had && return replace(line, field => "\"formatVersion\":\"2\""; count=1)
        s = rstrip(line)
        endswith(s, "}") || return nothing
        body = rstrip(s[1:prevind(s, lastindex(s))])
        return body * (endswith(body, "{") ? "" : ",") * "\"formatVersion\":\"2\"}"
    end
    for pat in (r"\s*,\s*\"formatVersion\"\s*:\s*\"[^\"\\]*\"", r"\"formatVersion\"\s*:\s*\"[^\"\\]*\"\s*,?\s*")
        occursin(pat, line) && return replace(line, pat => ""; count=1)
    end
    return nothing
end

"One map line converted from version `from` to `to`, with its newline; `lineno` is for error messages."
function _convertMapLine(line::String, from::String, to::String, lineno::Integer)::Vector{UInt8}
    from == to && return Vector{UInt8}(line * "\n")
    local x
    try
        x = _parse(line)
        x isa Dict{String,Any} || error("a map line must be a JSON object")
    catch e
        throw(AtlasFormatError("line $lineno: not a valid Atlas map line: failed to parse as JSON " *
                               "($(sprint(showerror, e)))."))
    end
    field, other = from == "1" ? ("districting", "assignment") : ("assignment", "districting")
    haskey(x, field) ||
        throw(AtlasFormatError("line $lineno$(_mapName(x)): the header declares formatVersion \"$from\" but the " *
                               "map line has no \"$field\"$(haskey(x, other) ? " (it has \"$other\")" : "")."))
    haskey(x, other) && throw(AtlasFormatError("line $lineno$(_mapName(x)): the map line has both " *
                                               "\"districting\" and \"assignment\"."))
    name = get(x, "name", "")
    name isa AbstractString || (name = "")
    try
        d = from == "1" ? _districtingFromV1(x[field]) : _assignmentToDistricting(x[field], x)
        start = _lastTopLevelKeyStart(line)
        cu = codeunits(line)
        key = codeunits("\"$field\"")
        (start > 0 && start + length(key) - 1 <= length(cu) && view(cu, start:start + length(key) - 1) == key) ||
            throw(AtlasFormatError("the assignment (\"$field\") must be the map line's last field, as " *
                                   "atlas_format.md requires; convertAtlas only rewrites that field."))
        io = IOBuffer(sizehint = length(cu))
        write(io, view(cu, 1:start - 1))                 # name, weight, data: byte for byte
        if to == "2"
            write(io, "\"assignment\":", _assignmentJSON(d).value)
        else
            write(io, "\"districting\":", _districtingJSONSorted(d).value)
        end
        write(io, "}\n")
        return take!(io)
    catch e
        msg = e isa AtlasFormatError ? replace(e.msg, r"^cannot write format v2: " => "cannot convert to v2: ") :
                                       "not a valid Atlas map line: $(sprint(showerror, e))."
        throw(AtlasFormatError("line $lineno$(isempty(name) ? "" : " (map \"$name\")"): $msg"))
    end
end

"""
Byte index of the opening quote of the last key of the top-level JSON object in `s`, or 0. Tracks nesting and
strings (with escapes), so keys and text inside nested values and strings are skipped.
"""
function _lastTopLevelKeyStart(s::AbstractString)
    cu = codeunits(s)
    depth = 0
    instr = esc = expectKey = false
    last = 0
    @inbounds for i in eachindex(cu)
        c = cu[i]
        if instr
            if esc
                esc = false
            elseif c == UInt8('\\')
                esc = true
            elseif c == UInt8('"')
                instr = false
            end
        elseif c == UInt8('"')
            instr = true
            depth == 1 && expectKey && (last = i)
            expectKey = false
        elseif c == UInt8('{') || c == UInt8('[')
            depth += 1
            expectKey = depth == 1 && c == UInt8('{')
        elseif c == UInt8('}') || c == UInt8(']')
            depth -= 1
            expectKey = false
        elseif c == UInt8(',')
            expectKey = depth == 1
        elseif !(c == UInt8(' ') || c == UInt8('\t') || c == UInt8('\n') || c == UInt8('\r'))
            expectKey = false
        end
    end
    return last
end

end # module AtlasIO
