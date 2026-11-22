# Generates the FROZEN v1 fixtures in test/fixtures/v1/ with AtlasIO 0.1.5 (the last JSON3-based release).
#
# These files pin exactly what v1 AtlasIO wrote, so every later version can be checked against them.
# Do NOT regenerate them with a newer AtlasIO: the guard below refuses to run on anything but 0.1.5 + JSON3.
#
# Run from the repository root:
#     julia --project=. test/fixtures/generate_v1_fixtures.jl
# then regenerate the expected values (an independent Python reader, not AtlasIO):
#     python3 test/fixtures/make_python_fixture.py
#     python3 test/fixtures/make_expected.py
#
# Names (map names and district-key names) contain no control characters: v1 keys holding them are not
# strictly valid JSON (Python's json.loads rejects them unless strict=False), so they are left out of the
# frozen format on purpose.

using AtlasIO

(pkgversion(AtlasIO) == v"0.1.5" && isdefined(AtlasIO, :JSON3)) ||
    error("generate_v1_fixtures.jl must run with AtlasIO 0.1.5 (JSON3-based); found $(pkgversion(AtlasIO)). " *
          "The v1 fixtures are frozen and must not be regenerated with a newer AtlasIO.")

const OUT = joinpath(@__DIR__, "v1")
mkpath(OUT)

const D = Districting
const DA = Dict{String,Any}

# --- edge-case atlas (Int64 weights) ---------------------------------------------------------------
edgeHeader = AtlasHeader("v1 edge-case fixture", "2026-11-22T00:00:00", "Dict{String, Any}", "Dict{String, Any}")
edgeParams = DA("levels in graph" => ["county", "prec_id"], "pi" => 3.141592653589793, "gamma" => 0.0,
                "districts" => 14, "nested" => DA("a" => [1.0, 2.0], "b" => "é"))
edgeMaps = [
    Map{DA}("ünïcødé \"quoted\" \\ back/slash, comma [br] {brace}",
            D(("a\"b", "c\\d") => 1, ("é",) => 2, ("x, y",) => 3, ("[br]",) => 4,
              ("p3", "c7", "b100") => 5, ("中文", "😀") => 6, ("it's",) => 7),
            3,
            DA("floats" => [0.1, 1e-7, 1e20, 1e300, 5e-324, -0.0, 1.0, 123456789.0, 2.5e15, 0.0],
               "ints" => [typemax(Int64), typemin(Int64), 0, -1],
               "bool" => true, "null" => nothing,
               "nested" => DA("x" => Any[1, "two", 3.0, Any[]], "deeper" => DA("y" => 0.5)),
               "empty" => DA(), "emptylist" => Any[],
               "text" => "line1\nline2\ttabbed \"q\" é")),
    Map{DA}("empty districting", D(), 1, DA("k" => "v")),
    Map{DA}("single", D(("37011",) => 14), 7, DA()),
    Map{DA}("weight zero", D(("A",) => 1, ("B", "p1") => 2, ("B", "p2") => 1), 0,
            DA("gamma" => 0.0, "energy weights" => [1.0, 0.5])),
]

plain = joinpath(OUT, "edge.jsonl")
open(plain, "w") do io
    newAtlas(io, edgeHeader, edgeParams)
    for m in edgeMaps
        addMap(io, m)
    end
end
plainBytes = read(plain)

# Same content through AtlasIO's compressed writers.
for ext in (".jsonl.gz", ".jsonl.bz2")
    io = smartOpen(joinpath(OUT, "edge" * ext), "w")
    write(io, plainBytes)
    close(io)
end

# Multi-member gzip, as AtlasOutput writes it: header member, then one member per map (target = 1 byte).
lines = readlines(plain)
open(joinpath(OUT, "edge_multimember.jsonl.gz"), "w") do io
    write(io, gzipMember(atlasHeaderBytes(plain)))
    writeGzipMembers!(io, [Vector{UInt8}(l * "\n") for l in lines[4:end]], 1; target = 1)
end

# --- Float64-weight atlas (weightType is per file, so it needs its own file) ------------------------
floatHeader = AtlasHeader("v1 float-weight fixture", "2026-11-22T00:00:00", "Dict{String, Any}",
                          "Dict{String, Any}"; weightType = "Float64")
floatMaps = [
    Map{DA}("half", D(("A",) => 1), 0.5, DA("x" => 1)),
    Map{DA}("whole float", D(("A",) => 2), 2.0, DA()),
    Map{DA}("tiny", D(("A",) => 1, ("B",) => 2), 1e-300, DA()),
    Map{DA}("third", D(("B", "p1") => 3), 0.3333333333333333, DA("w" => 0.0)),
]
open(joinpath(OUT, "edge_float.jsonl"), "w") do io
    newAtlas(io, floatHeader, DA())
    for m in floatMaps
        addMap(io, m)
    end
end

println("wrote v1 fixtures to ", OUT, ":")
foreach(f -> println("  ", f, "  ", filesize(joinpath(OUT, f)), " bytes"), sort(readdir(OUT)))
