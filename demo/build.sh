#!/usr/bin/env bash
# Assemble demo/payday-autopilot-demo.mp4 from cards + terminal recordings (live testnet runs).
set -e; cd "$(dirname "$0")"
V="scale=1280:720:force_original_aspect_ratio=decrease,pad=1280:720:(ow-iw)/2:(oh-ih)/2:color=0x0e111c,fps=25,format=yuv420p"
mk_card() { ffmpeg -y -loglevel error -loop 1 -t $2 -i $1 -vf "$V" -c:v libx264 -preset veryfast -r 25 seg_$1.mp4; echo seg_$1.mp4 >> order; }
mk_gif()  { ffmpeg -y -loglevel error -i $1 -vf "$V" -c:v libx264 -preset veryfast -r 25 seg_$1.mp4; echo seg_$1.mp4 >> order; }
rm -f order
mk_card c1.png 7; mk_card c2.png 14; mk_card c3.png 4; mk_gif tests.gif
mk_card c4.png 9; mk_gif live2.gif; mk_gif live3.gif; mk_gif live4.gif; mk_card c5.png 14
sed "s/.*/file '&'/" order > list.txt
ffmpeg -y -loglevel error -f concat -safe 0 -i list.txt -c copy payday-autopilot-demo.mp4
rm -f seg_*.mp4 list.txt order
ffprobe -v error -show_entries format=duration -of csv=p=0 payday-autopilot-demo.mp4
