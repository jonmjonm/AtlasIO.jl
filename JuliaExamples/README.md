# Julia Examples

Small scripts showing how to use `AtlasIO` from Julia.

## `read_atlas.jl`

Basic serial read — opens an atlas and iterates maps one at a time with `nextMap`.

```bash
julia read_atlas.jl ../ExampleAtlas/atlas_truncated_nc_multiscale.jsonl
julia read_atlas.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 20
```

## `parallel_read_write.jl`

Multithreaded read and write. `nextMaps` parses maps across all
available threads; `addMaps` serializes and writes a batch of maps in parallel.
Both give results identical to the serial `nextMap` / `addMap` paths — same
on-disk order, byte-identical output.

**Start Julia with multiple threads** (`-t auto`), or these run serially:

```bash
# read the first 2000 maps in parallel
julia -t auto parallel_read_write.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 2000

# read, then write the maps back out to a new atlas (and verify the round-trip)
julia -t auto parallel_read_write.jl ../ExampleAtlas/atlas_nc_multiscale.jsonl.gz 2000 copy.jsonl
```
