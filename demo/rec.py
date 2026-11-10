#!/usr/bin/env python3
"""Tiny asciicast v2 recorder: rec.py out.cast "command" [cols rows]"""
import os, pty, sys, time, json, select, subprocess
out, cmd = sys.argv[1], sys.argv[2]
cols, rows = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (110, 34)
pid, fd = pty.fork()
if pid == 0:
    os.environ.update(COLUMNS=str(cols), LINES=str(rows), TERM="xterm-256color")
    os.execvp("bash", ["bash", "-c", cmd])
t0 = time.time(); ev = []
while True:
    try:
        r, _, _ = select.select([fd], [], [], 0.1)
        if r:
            d = os.read(fd, 4096)
            if not d: break
            ev.append([round(time.time() - t0, 3), "o", d.decode("utf8", "replace")])
    except OSError:
        break
os.waitpid(pid, 0)
with open(out, "w") as f:
    f.write(json.dumps({"version": 2, "width": cols, "height": rows, "timestamp": int(t0)}) + "\n")
    for e in ev: f.write(json.dumps(e) + "\n")
