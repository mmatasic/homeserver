#!/bin/bash
# requires: ffmpeg
./sacd_extract -2 -s -C -i *.iso -o . 

find . -type f -name "*.dsf" -exec mv "{}" . \;

for f in *.dsf; do ffmpeg -i "$f" -c:a flac -sample_fmt s16 -ar 48000 -compression_level 8 "${f%.dsf}.flac"; done

rm *.dsf

find . -type d -empty -delete
