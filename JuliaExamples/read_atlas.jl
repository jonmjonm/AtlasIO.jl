##
## This is a very basic script. It just reads in the maps
##
## Usage
# julia read_atlas.jl <atlas name> <optional: num maps>
#
## Example
# julia read_atlas.jl ../ExampleAtlas/atlas_truncated_nc_multiscale.jsonl
# julia read_atlas.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 20


using Pkg
using AtlasIO
@show ARGS

atlasFileName = ARGS[1] # Get the file name
if length(ARGS)>1       # get number of maps set to Inf if none given
    maxMap=parse(Int64,ARGS[2])
else
    maxMap=Inf
end

println("Running....on file ", atlasFileName)

openAtlas(atlasFileName) do atlas     # closed at the end, even after the break below
    println("atlas date:",atlas.date)
    println("number of districts:",atlas.atlasParam["districts"])
    mapCount=0
    for m in eachMap(atlas)
        mapCount+=1
        if (mapCount > maxMap)
            break
        end
        println("map count:", mapCount, "\t map name:",m.name,
            " \t number of assignments in districting:",length(m.districting))
    end
end

