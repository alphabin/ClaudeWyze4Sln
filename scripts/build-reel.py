#!/usr/bin/env python3
"""Highlight reel: the newest 'she's out' clips (her on the move, auto-clipped by the bot) -> overlay/reel.mp4 (960x540, silent, looped by OBS).
Slugs come from the bot's own log lines 'clip requested (she's out): <slug>' (Twitch clip titles are just the stream title). Needs yt-dlp + ffmpeg."""
import os, re, subprocess, sys, glob, time
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); LOG = os.path.expanduser("~/Library/Logs/snakecam-chatbot.log")
N = int(sys.argv[1]) if len(sys.argv) > 1 else 12; D = f"{ROOT}/overlay/reel"; os.makedirs(f"{D}/src", exist_ok=True)
slugs = []
for line in open(LOG, errors="ignore"):
    m = re.search(r"clip requested \((she's out|patrol[^)]*|requested by [^)]*)\): (\S+)", line)
    if m and m.group(2) not in slugs: slugs.append(m.group(2))
slugs = slugs[-N:]
if not slugs: print("no movement clips in the log yet"); sys.exit(0)
have = []
for s in slugs:
    f = f"{D}/src/{s}.mp4"
    if not os.path.exists(f):
        r = subprocess.run(["/opt/homebrew/bin/yt-dlp", "-q", "--no-warnings", "-o", f, f"https://clips.twitch.tv/{s}"], capture_output=True, text=True)
        if r.returncode: print("skip", s, r.stderr.strip()[:80]); continue
    have.append(f)
for old in glob.glob(f"{D}/src/*.mp4"):                         # keep the folder to the reel's size
    if old not in have and time.time() - os.path.getmtime(old) > 7 * 86400: os.remove(old)
if not have: print("nothing downloaded"); sys.exit(1)
lst = f"{D}/list.txt"; open(lst, "w").write("".join(f"file '{f}'\n" for f in have))
tmp = f"{D}/reel.tmp.mp4"; out = f"{ROOT}/overlay/reel.mp4"
subprocess.run(["/opt/homebrew/bin/ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", lst, "-an", "-vf", "crop=iw*0.40:ih*0.40:iw*0.55:ih*0.31,scale=960:540,fps=30",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-pix_fmt", "yuv420p", "-movflags", "+faststart", tmp], check=True)
os.replace(tmp, out); print(f"reel: {len(have)} clips -> {out}")
