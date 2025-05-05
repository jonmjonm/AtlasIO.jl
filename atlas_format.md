# Atlas Format

The Atlas format is a JSONL (JSON Lines) format adapted hold distric maps from redistricting efforts. 
* This first line is a comment that discribs the format. 
* The second line is a JSON object that describes the basic information of the collection of maps saved in this Atlas. 
* The third line is a JSON object that describes the extra data assigned to each map. It can be adapted to the particular setting. In particular, it gives that data times and key names associated to the additional data.
* Each of the following lines, starting with the 4th line, is a JSON object a JSON object that describes a map and its associated data.

