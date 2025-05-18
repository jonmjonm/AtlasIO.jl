## Usage
# julia read_atlas.jl <atlas name>
#
## Example
# julia process_atlas.jl ../../atlas_output ../../analysis_output Grid_4x4 ../../graphs/grid_graph_4_by_4.json
#

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
    println("map count:", mapCount, "\t map name:",m.name, " \t number of alignment in districting:",length(m.districting))
    @show 
end








 
