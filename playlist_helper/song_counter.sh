#!/bin/bash
pushd $1
/bin/find . -type f -name "*.mp3" -o -name "*.flac" | cut -d/ -f2 | sort | uniq -c | sort -nr 
popd
