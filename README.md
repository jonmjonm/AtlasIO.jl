# AtlasIO


[![Test CI](https://github.com/jonmjonm/AtlasIO.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/jonmjonm/AtlasIO.jl/actions/workflows/ci.yml)

This repository contains a number of tools to read in and manipulate Atlas files. The primary code is written in the Julia programming language, but it can be used in Python as well. The Julia library and the Python `atlasio` package both read and write Atlas files and convert them between format versions.

For a complete reference of the public functions and types exposed by both the Julia and Python libraries, see [**function_calls.md**](function_calls.md).

## Reading Atlas files in Python

From AtlasIO 0.2.1 there are two Python readers. Both read format v1 and v2 files, plain or compressed (`.gz`, `.bz2`), and need only the standard library. From 0.2.2 the `atlasio` package also converts files between v1 and v2: `python -m atlasio convert IN OUT --to 2`. From 0.2.3 it also writes Atlas files (`atlasio.new_atlas`; see [Writing Atlas files in Python](#writing-atlas-files-in-python)).

* **The `atlasio` package** (new, in [python/](python)). District keys are tuples, as in Julia: `("MECKLENBURG", "052")`. Install it from PyPI (from 0.2.4):

  ```
  pip install atlasio
  ```

  or straight from a release tag of this repository: `pip install "atlasio @ git+https://github.com/jonmjonm/AtlasIO.jl@v0.2.4#subdirectory=python"`.

  ```python
  import atlasio
  with atlasio.open_atlas("atlas.jsonl.gz") as atlas:
      for m in atlas:
          m.name, m.weight, m.data, m.districting
  ```

* **[PythonReader/AtlasIO.py](PythonReader/AtlasIO.py)** (the original single file, kept so existing code works unchanged). District keys are strings such as `'["MECKLENBURG", "052"]'`. Load it by adding `PythonReader/` to `sys.path`, or with [httpimport](https://pypi.org/project/httpimport/) pinned to a release tag, so that later changes on `main` cannot change your results:

  ```python
  with httpimport.remote_repo(['AtlasIO'], 'https://raw.githubusercontent.com/jonmjonm/AtlasIO.jl/refs/tags/v0.2.4/PythonReader/'):
      import AtlasIO
  ```


## Writing Atlas files in Python

From 0.2.3 the `atlasio` package writes Atlas files too, format v1 (the default, as in Julia) or v2, plain or compressed by extension:

```python
import atlasio
with atlasio.new_atlas("ensemble.jsonl.gz", description="my ensemble", params={"districts": 14}) as out:
    for i, plan in enumerate(plans):                          # plan: {("WAKE",): 3, ("MECKLENBURG", "052"): 13, ...}
        out.add_map("step%d" % i, plan, weight=1, data={"score": 0.5})
```

To write a modified copy of an atlas, `atlasio.new_atlas(dst, like=src_atlas)` copies its header and parameters. The files are laid out exactly as AtlasIO.jl writes them, and AtlasIO.jl reads them back unchanged.

## Atlas files 
    
Atlas files contain a collection of map assignments. The format is a specialization of the JSONL format. Each line in an Atlas file is a JSON object. The first three lines describe the particular Atlas. Starting with the fourth line, each line is a JSON object that describes a map assignment. More information can be found in the [**Atlas format**](atlas_format.md) file.  

The Julia library's `smartOpen` can open a local file (compressed or not) or an `http://`/`https://` URL directly for reading -- see [**function_calls.md**](function_calls.md) for details.

The Atlas format is the format used by the [Quantifying Gerrymandering](https://duke.is/QGBlog) project's redistricting sampling software, including [**Cycle Walk**](https://duke.is/CycleWalk) and [**Metropolized Forest Recom**](https://duke.is/MFRecom), to save their ensembles of maps.

## Directory Structure of AtlasIO repository
The directory structure of the AtlasIO repository is as follows:

```
README.md
atlas_format.md
function_calls.md
LICENSE
+-- src
|       AtlasIO.jl
+-- ExampleAtlas
|       atlas_nc_multiscale.jsonl.gz
|       atlas_truncated_nc_multiscale.jsonl
|       test.jsonl
|       test.jsonl.gz
+-- JuliaExamples
|       read_atlas.jl
|       parallel_read_write.jl
+-- python                 (the atlasio package)
|       pyproject.toml
|       src/atlasio/__init__.py
+-- PythonReader
|       AtlasIO.py
|       helper_functions.py
+-- PythonExamples
|       example_atlas.py
|       example_atlas_multilevel_loadMaps.py
|       example_atlas_multilevel_precinctHistogram.py
+-- Shapefile_JSON
|       pct21_20votes_wMCD.json
|       pct21_22votes.json
|       pct21.zip    
```
## The files contained here are : 
* [README.md](README.md) : 
    This file contains a description of the repository and how to use it.
* [atlas_format.md](atlas_format.md) :
    This file contains a description of the Atlas file format. It describes the JSONL format and the different fields in the JSON objects.
* [function_calls.md](function_calls.md) :
    This file documents the public function calls and types of both the Julia and Python libraries (an API reference).
* [LICENSE](LICENSE) :
    This file contains the license for the repository. The code is licensed under the MIT license.
* [src](src) directory
    - [AtlasIO.jl](src/AtlasIO.jl):
        This is the main Atlas reader and writer module written in Julia. 
* [ExampleAtlas](ExampleAtlas) directory
    - [atlas_nc_multiscale.jsonl.gz](ExampleAtlas/atlas_nc_multiscale.jsonl.gz) :
        This is a large collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files. These multi-scale assignments come from code which try to preserve the different levels.
    - [atlas_truncated_nc_multiscale.jsonl](ExampleAtlas/atlas_truncated_nc_multiscale.jsonl) :
        This is part of a real Atlas file for testing. It is uncompressed. 
    - [test.jsonl](ExampleAtlas/test.jsonl) :
        This is a small hand made collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files.
    - atlas_measureID.jsonl.gz :
        This is a large collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files. These multi-scale assignments come from code which try to preserve the different levels. This ensembles was used in a North Carolina 2021 court case. More info can be found in the [original repos](https://git.math.duke.edu/gitlab/gjh/ncanalysis2020/-/tree/main/ensembles/congressional).   
* [PythonReader](PythonReader) Directory : This directory contains python code to read Atlas files and analyze them.
    - [AtlasIO.py](PythonReader/AtlasIO.py) :
        The original single-file Atlas reader. It can read compressed or uncompressed files, format v1 and v2, with district keys as strings. It can not write an Atlas file; use the `atlasio` package or the Julia library for that. New code can use the `atlasio` package instead (see [Reading Atlas files in Python](#reading-atlas-files-in-python)).
    - [helper_functions.py](PythonReader/helper_functions.py) :
        Some helper functions that are useful. Examples include summing elections, performing uniform swings and obtaining the node name to district mapping. See the file for full list and description.

* [Shapefile_JSON](Shapefile_JSON) Directory : 
    This contains some election data and the adjacency data. Some files are in JSON files and others are in zipped shapefiles.

* [PythonExamples](PythonExamples) Directory : 
    This directory contains some examples of how to use the Atlas reader library. 
    - [example_atlas.py](PythonExamples/example_atlas.py) :
        This is a simple example of how to use the Atlas reader library. It reads in a file and prints out the number of maps and the number of precincts in each map.
    - [example_atlas_multilevel_loadMaps.py](PythonExamples/example_atlas_multilevel_loadMaps.py) :
        This is an example of how to load a multi-level Atlas file. It reads in a file and prints out the number of maps and the number of precincts in each map.
    - [example_atlas_multilevel_precinctHistogram.py](PythonExamples/example_atlas_multilevel_precinctHistogram.py) :
        This is an example of how to load a multi-level Atlas file and create a histogram of the precincts. It reads in a file and prints out the histogram.

* [JuliaExamples](JuliaExamples) Directory :
    This directory contains some examples of how to use the Atlas reader library. 
    - [read_atlas.jl](JuliaExamples/read_atlas.jl) : a simple example that loops through the maps 
    
## Quantifying Gerrymandering project
This repository is part of the [Quantifying Gerrymandering](https://duke.is/QGBlog) project. The goal of this project is to develop tools to quantify gerrymandering and to provide a platform for researchers to share their work. The project is led by a team of researchers at Duke University, including Professor Jonathan Mattingly, Professor Greg Herschlag, and many others. More information about the project can be found on the [**Quantifying Gerrymandering**](https://duke.is/QGBlog) website and in the [**Quantifying Gerrymandering Documentation**](https://duke.is/QGDoc).

The Quantifying Gerrymandering Project's redistricting sampling software uses the Atlas format to save its data. Both [**Cycle Walk**](https://duke.is/CycleWalk) and [**Metropolized Forest Recom**](https://duke.is/MFRecom) write their ensembles of map assignments in the [Atlas format](atlas_format.md).
