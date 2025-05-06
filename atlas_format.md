# Atlas File Format

The Atlas format is a JSONL (JSON Lines) format adapted hold district maps from redistricting efforts. The Atlas format is a simple extension of the JSONL format that allows for the storage of maps and their associated data in a single file. The [AtlasIO.jl Julia library](https://git.math.duke.edu/gitlab/jonm/atlasio.jl/) provides the ability to read and write Atlas files. The [AtlasIO.py Python library](https://git.math.duke.edu/gitlab/jonm/atlasio.jl/-/tree/main/PythonReader), from the same git repository, provides the read but not the write functionality. This format was developed by the [Duke Quantifying Gerrymandering Group](https://sites.duke.edu/quantifyinggerrymandering/). 
## Structure of an Atlas File
Each individual line of an Atlas file is JSON object. As such they can be read line by line unlike a single JSON. 
* This first line is a comment that identifies the file as an Atlas of maps and describes the Atlas format. 
* The second line is a JSON object that describes the basic information of the collection of maps saved in this Atlas. 
* The third line is a JSON object that describes the extra data assigned to each map. It can be adapted to the particular setting. In particular, it gives that data times and key names associated to the additional data.
* Each of the following lines, starting with the 4th line, is a JSON object a JSON object that describes a map and its associated data.

## File Extension and Compression

Atlas files the file extension `.jsonl` if the file in Atlas is plan, uncompressed text. If the Atlas is compressed it will either use the file extension `.jsonl.gz` or `.jsonl.bz2`. 

The `.gz` extension signifies the use of the standard [**Gnu Zip tools**](https://en.m.wikipedia.org/wiki/Gzip) (`gzip`, `gunzip`, `zcat`) and can be read by a number of libraries and command line tools. These tools use the standard Deflate algorithm to compress data.

The `.bz2`  extension signifies the use of the standard 
[**BZip2 tools**](https://en.m.wikipedia.org/wiki/Bzip2) (`bzip2`, `bzcat`) and also can be read by a number of libraries and command line tools. These tools use the standard Burrows–Wheeler algorithm to compress data.

The Bzip2 compression format typically results is smaller file that the Gzip compression format. However, the Bzip2 compression is slower to compress and uncompressed. We also explored saving files by saving the incremental changes in the maps. However, it was decided that the advantage of using standard compression tools was significant in light of the very high compression rations they delivered out of the box.

## Work Directly with Compress Files

One nice feature of the AtlasIO libraries, both in Julia and Python, is that they can read and write compressed files directly. This both increase the speed of writing and decreases the size of the Atlas files significantly.

### Corrupted Compressed Files

One downside of directly writing compressed files is that the files can not be directly examined during the run and might be left in a corrupted state if the run is interrupted. A corrupted file can typically easily be largely recovered using  

`` zcat atlas-corrupted.jsonl.gz >  atlas-fixed.jsonl ``  

You can also use the `zcat` command to examine a file during a run.
