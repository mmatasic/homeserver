#!/bin/bash
pushd $1
/bin/find . -type f -name "*.mp3" -o -name "*.flac" | cut -d/ -f2 | sort | uniq -c | sort -nr | rg " 1 " | tr -s ' ' | cut -d ' ' -f3,4,5,6,7,8,9
popd
