# AtlasIO

This repository a number of tools to read in and manipulate Atlas files. The primary code is written in the Julia programming language, but it can be used in Python as well.

## Atlas files
    
Atlas files contain a collection of map assignments. The format is a specialization of the JSONL format. Each line in an Atlas file is a JSON object. THe first three lines describe the particular Atlas. Starting with the fourth line, each line is a JSON object that describes a map assignment. More information can be found in the [**Atlas format**](atlas_format.md) file.  

## Directory Structure of AtlasIO repository
The directory structure of the AtlasIO repository is as follows:

```
+-- AtlasIO
|       AtlasIO.jl
+-- AtlasExamples
|       atlas_nc_multiscale.jsonl.gz
|       atlas_truncated_nc_multiscale.jsonl
|       test.jsonl.gz
+-- JuliaExamples
+-- PythonReader
|       Atlas.py
|       helper_functions.py
+-- PythonExamples
|       example_atlas.py
|       example_atlas_multilevel_loadMaps.py
|       example_atlas_multilevel_precinctHistogram.py
+--  Shapefiles_JSON
|       pct21_20votes_wMCD.json
|       pct21_22votes.json
|       pct21.zip    
```
## The files contained here are : 
* AtlasIO directory
    - AtlasIO.jl:
        This is the main Atlas reader and writer library written in Julia. 
* AtlasExamples directory
    - atlas_nc_multiscale.jsonl.gz :
        This is a large collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files. These multi-scale assignments come from code which try to preserve the different levels.
    - atlas_truncated_nc_multiscale.jsonl :
        This is part of a real Atlas file for testing. It is uncompressed. 
    - test.jsonl :
        This is a small hand made collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files.
    - atlas_measureID.jsonl.gz :
        This is a large collection of map assignments for testing. Notice that it is compressed. The library can read compressed or uncompressed files. These multi-scale assignments come from code which try to preserve the different levels. This ensembles was used in NC 2021 court case. More info can be found in the [original repos](https://git.math.duke.edu/gitlab/gjh/ncanalysis2020/-/tree/main/ensembles/congressional)   
* PythonReader Directory : This directory contains python code to read Atlas files and analyze them.
    - Atlas.py :
        This is the main Atlas reader Library. It is a python version of the Julia library. It can read compressed or uncompressed files.
    - helper_functions.py :
        Some helper functions that are useful.

* Shapefiles_JSON Directory : 
    This contains some election data and the adjacency data. Some files are in JSON files others are in ziped shapefiles.

* PythonExamples Directory : 
    This directory contains some examples of how to use the Atlas reader library. 
    - example_atlas.py :
        This is a simple example of how to use the Atlas reader library. It reads in a file and prints out the number of maps and the number of precincts in each map.
    - example_atlas_multilevel_loadMaps.py :
        This is an example of how to load a multi-level Atlas file. It reads in a file and prints out the number of maps and the number of precincts in each map.
    - example_atlas_multilevel_precinctHistogram.py :
        This is an example of how to load a multi-level Atlas file and create a histogram of the precincts. It reads in a file and prints out the histogram.

* JuliaExamples Directory :
    This directory contains some examples of how to use the Atlas reader library. 
    
## Quantifying Gerrymandering project
This repository is part of the Quantifying Gerrymandering project. The goal of this project is to develop tools to quantify gerrymandering and to provide a platform for researchers to share their work. The project is led by a team of researchers at Duke University, including Professor Jonathan Mattingly, Professor Greg Herschlag, and many others. More information about the project can be found on the [**Quantifying Gerrymandering**](https://www.quantifyinggerrymandering.com/) website.