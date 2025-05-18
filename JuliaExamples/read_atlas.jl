## Usage
# julia read_atlas.jl <atlas name>
#
## Example
# julia read_atlas.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz


using Pkg
push!(LOAD_PATH, "../src/");
using AtlasIO

atlasFileName = ARGS[1]

println("Running....on file ", atlasFileName)

io=smartOpen(atlasFileName, "r")
atlas=openAtlas(io);
################
mapCount=0
maxMap=5
 
while !AtlasIO.eof(atlas)
    m = nextMap(atlas) 
    global mapCount+=1
    if mapCount > maxMap 
        break
    end
    println("map count:", mapCount, "\t map name:",m.name, " \t number of assignments in districting:",length(m.districting))
end








 
