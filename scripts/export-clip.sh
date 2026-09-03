#!/bin/zsh
# Export Twitch clips as vertical 9:16 MP4s with a caption, ready for TikTok / Reels / Shorts.
# usage: ./scripts/export-clip.sh                 -> the newest 3 clips of the channel
#        ./scripts/export-clip.sh 10              -> the newest 10
#        ./scripts/export-clip.sh <clip url>      -> that clip
# Output: ~/Desktop/CleoClips/<date>-<title>.mp4 (+ .txt with a suggested caption). Needs yt-dlp + ffmpeg + chatbot/token.json.
set -e; cd "$(dirname "$0")/.."; OUT=~/Desktop/CleoClips; mkdir -p "$OUT"
python3 - "$@" <<'PY'
import json,os,re,subprocess,sys,urllib.request,urllib.parse
ROOT=os.getcwd(); OUT=os.path.expanduser("~/Desktop/CleoClips")
env=dict(l.split("#")[0].strip().split("=",1) for l in open(f"{ROOT}/.env") if "=" in l.split("#")[0]); cid=env["TWITCH_CLIENT_ID"].strip(); chan=env["TWITCH_CHANNEL"].strip().lower()
tok=json.load(open(f"{ROOT}/chatbot/token.json"))["access_token"]; H={"Authorization":"Bearer "+tok,"Client-Id":cid}
def get(p): return json.load(urllib.request.urlopen(urllib.request.Request("https://api.twitch.tv/helix/"+p,headers=H)))["data"]
arg=sys.argv[1] if len(sys.argv)>1 else "3"
if arg.startswith("http"): clips=[{"url":arg,"title":"clip","created_at":"","id":arg.rstrip("/").split("/")[-1]}]
else:
    bid=get(f"users?login={chan}")[0]["id"]; clips=get(f"clips?broadcaster_id={bid}&first={int(arg)}")
for c in clips:
    slug=re.sub(r"[^a-z0-9]+","-",c["title"].lower()).strip("-")[:40] or "clip"; day=(c.get("created_at") or "")[:10] or "clip"
    src=f"{OUT}/.{c['id']}.mp4"; dst=f"{OUT}/{day}-{slug}.mp4"
    if os.path.exists(dst): print("skip (exists)", dst); continue
    if not os.path.exists(src): subprocess.run(["yt-dlp","-q","-o",src,c["url"]],check=True)
    cap="Princess Cleo, the ball python who reads tarot. Live 24/7 on Twitch, twitch.tv/princesscleolive"
    txt=cap.replace("\\","\\\\").replace(":","\\:").replace("'","\\'").replace(",","\\,"); font="/System/Library/Fonts/Supplemental/Arial Bold.ttf"
    # 1080x1920: crop the centre of the 16:9 frame (the reading panel lives there), letterbox top/bottom with a blurred copy, caption at the top
    vf=("[0:v]scale=1080:1920:force_original_aspect_ratio=increase,crop=1080:1920,boxblur=20:8[bg];"
        "[0:v]scale=1080:-2[fg];[bg][fg]overlay=(W-w)/2:(H-h)/2")   # caption lives in the .txt next to it (Homebrew ffmpeg has no drawtext)
    subprocess.run(["/opt/homebrew/bin/ffmpeg","-loglevel","error","-y","-i",src,"-filter_complex",vf,"-c:v","libx264","-preset","veryfast","-crf","20","-c:a","aac","-b:a","128k","-movflags","+faststart",dst],check=True)
    os.remove(src); open(dst[:-4]+".txt","w").write(f"{c['title']}\n\n{cap}\n#ballpython #snake #tarot #twitch #animalcam #cozy\n"); print("exported", dst)
PY
echo "done -> $OUT"
