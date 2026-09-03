#!/bin/bash
# quickstream.sh - a Wyze Cam Pan V4 (HL_PAN4) as a local RTSP / WebRTC stream, nothing else.
#
#   ./quickstream.sh                 first run: checks tools, asks for Wyze login, starts everything, proves it
#   ./quickstream.sh start [cam...]  same; pass camera names to skip the question
#   ./quickstream.sh status          are frames still advancing? (asks the headless Chrome over CDP)
#   ./quickstream.sh stop            stop the decoder(s) and mediamtx (containers keep running)
#   ./quickstream.sh down            stop + docker compose down
#   ./quickstream.sh logs [cam]      tail the relay / decoder logs
#
# Chain:  camera -> Wyze/Agora cloud -> headless Chrome (www/lake.html decodes H.265, re-encodes H.264)
#         -> WHIP -> mediamtx -> rtsp://127.0.0.1:8555/<cam>  and  http://localhost:8890/<cam>/
# Everything lives in this folder: .env, tokens/, www/lake/, logs/, run/. Delete the folder to uninstall.
set -u
cd "$(dirname "$0")" || exit 1
HERE=$(pwd)
BRIDGE=http://localhost:5050
PLAYER_BASE="$BRIDGE/static/quickstream"
RTSP_PORT=8555; WEBRTC_PORT=8890; CDP_BASE=9224
RES=${RES:-2k}                         # 360p | SD | HD | 2k  (camera-side; the relay is always <= 1080p)
mkdir -p tokens www/lake logs run

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[--]\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m[!!]\033[0m %s\n' "$*" >&2; exit 1; }
os=$(uname -s)

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- tools --------------------------------------
find_chrome() {
  local c
  if [ "$os" = Darwin ]; then
    for c in "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" "$HOME/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
             "/Applications/Chromium.app/Contents/MacOS/Chromium"; do [ -x "$c" ] && { echo "$c"; return; }; done
  else
    for c in google-chrome google-chrome-stable chromium chromium-browser; do command -v "$c" >/dev/null && { command -v "$c"; return; }; done
  fi
  return 1
}
hint() {   # hint <tool> : how to install it here
  case "$os:$1" in
    Darwin:docker)   echo "brew install --cask docker   (or: brew install colima docker docker-compose && colima start)";;
    Darwin:chrome)   echo "brew install --cask google-chrome";;
    Darwin:mediamtx) echo "brew install mediamtx";;
    Darwin:ffmpeg)   echo "brew install ffmpeg";;
    *:docker)        echo "https://docs.docker.com/engine/install/  (and the compose plugin)";;
    *:chrome)        echo "https://www.google.com/chrome/  or: apt install chromium";;
    *:mediamtx)      echo "download a release from https://github.com/bluenviron/mediamtx/releases and put mediamtx on your PATH";;
    *:ffmpeg)        echo "apt install ffmpeg";;
  esac
}
check_tools() {
  say "1/7 tools"
  local missing=0
  if command -v docker >/dev/null && docker info >/dev/null 2>&1; then ok "docker ($(docker compose version --short 2>/dev/null || echo 'compose?'))"
  else warn "docker not running or not installed -> $(hint docker)"; missing=1; fi
  if CHROME=$(find_chrome); then
    local v; v=$("$CHROME" --version 2>/dev/null | grep -oE '[0-9]+' | head -1)
    if [ "${v:-0}" -ge 130 ]; then ok "Chrome $v: $CHROME"
    else warn "Chrome ${v:-?} is too old: H.265 in WebRTC needs Chrome >= 130 -> $(hint chrome)"; missing=1; fi
    [ "$os" != Darwin ] && ok "Linux: using '$CHROME' as the headless decoder (on macOS it would be Google Chrome.app)"
  else warn "Chrome/Chromium not found -> $(hint chrome)"; missing=1; fi
  if command -v mediamtx >/dev/null; then ok "mediamtx: $(command -v mediamtx)"; else warn "mediamtx missing -> $(hint mediamtx)"; missing=1; fi
  if command -v ffmpeg >/dev/null;   then ok "ffmpeg: $(command -v ffmpeg)";     else warn "ffmpeg missing -> $(hint ffmpeg)"; missing=1; fi
  if command -v python3 >/dev/null;  then ok "python3";                          else warn "python3 missing (used to read the camera list and talk to Chrome)"; missing=1; fi
  command -v curl >/dev/null || { warn "curl missing"; missing=1; }
  [ $missing = 0 ] || die "install the missing pieces and run again"
}

# ---------------------------------------------------------------- credentials --------------------------------
# Same four values as ../bridge/setup-wyze.sh; written as a fresh file (portable: no sed -i differences).
setup_wyze() {
  say "2/7 Wyze login"
  if [ -f .env ] && grep -q '^WYZE_API_KEY=.\+' .env && [ "${1:-}" != force ]; then ok ".env present (run './quickstream.sh login' to change it)"; return; fi
  echo "  Your Wyze login plus an API key pair from https://developer-api-console.wyze.com/ (the key pair is what gets around 2FA)."
  local email pw kid key
  read -r  -p "  Wyze account email : " email
  read -rs -p "  Wyze password      : " pw; echo
  read -r  -p "  Key Id             : " kid
  read -r  -p "  API Key            : " key
  [ -n "$email" ] && [ -n "$pw" ] && [ -n "$kid" ] && [ -n "$key" ] || die "all four are required; nothing written"
  umask 077
  { echo "# written by quickstream.sh - your Wyze login; keep this file private"
    printf 'WYZE_EMAIL=%s\nWYZE_PASSWORD=%s\nWYZE_API_ID=%s\nWYZE_API_KEY=%s\n' "$email" "$pw" "$kid" "$key"; } > .env
  umask 022
  ok "saved to .env (mode 600)"
}

# ---------------------------------------------------------------- containers ---------------------------------
get_sdk() {
  [ -s www/agora-rtc-sdk.js ] && return
  echo "  fetching the Agora Web SDK (served locally by the bridge)"
  (cd www && ./get-agora-sdk.sh >/dev/null) && [ -s www/agora-rtc-sdk.js ] || die "could not download agora-rtc-sdk.js (see www/get-agora-sdk.sh)"
}
start_containers() {
  say "3/7 containers"
  get_sdk
  docker compose up -d --quiet-pull 2>&1 | sed 's/^/  /' || die "docker compose up failed"
  printf '  waiting for the bridge to log in and list cameras'
  local i=0
  while ! curl -sf -m 3 "$BRIDGE/api" 2>/dev/null | grep -q product_model; do
    i=$((i+1)); [ $i -gt 60 ] && { echo; die "bridge not up after 3 min: docker compose logs wyze-bridge   (wrong password / API key? 'quickstream.sh login')"; }
    printf .; sleep 3
  done; echo
  ok "bridge up at $BRIDGE"
}

# camera list from the bridge: "name<TAB>model<TAB>lake|other"
cam_table() {
  curl -sf -m 5 "$BRIDGE/api" | python3 -c '
import json, sys
d = json.load(sys.stdin); cams = d.get("cameras", d)
for name, c in cams.items():
    if not isinstance(c, dict): continue
    m = str(c.get("product_model", "?"))
    print(name + "\t" + m + "\t" + ("lake" if m == "HL_PAN4" else "other"))'
}
pick_cams() {
  say "4/7 cameras"
  local table; table=$(cam_table) || die "could not read the camera list from $BRIDGE/api"
  [ -n "$table" ] || die "the bridge lists no cameras on this account"
  local lakes=()
  while IFS=$'\t' read -r name model kind; do
    if [ "$kind" = lake ]; then lakes+=("$name"); printf '  \033[32m*\033[0m %-24s %-10s lake (Agora / H.265)  <- this kit streams these\n' "$name" "$model"
    else                        printf '    %-24s %-10s %s\n' "$name" "$model" "not a lake camera: the bridge itself can stream it (docker-wyze-bridge docs), this kit does not"; fi
  done <<< "$table"
  [ ${#lakes[@]} -gt 0 ] || die "no HL_PAN4 / lake camera on this account (see ../WRITEUP.md section 1)"
  if [ $# -gt 0 ]; then CAMS=("$@")
  elif [ ${#lakes[@]} = 1 ]; then CAMS=("${lakes[0]}"); ok "streaming ${lakes[0]}"
  else
    read -r -p "  which camera(s)? [space-separated names, or 'all'] (all): " ans
    if [ -z "$ans" ] || [ "$ans" = all ]; then CAMS=("${lakes[@]}"); else read -r -a CAMS <<< "$ans"; fi
  fi
  for c in "${CAMS[@]}"; do awk -F"	" -v c="$c" '$1==c{f=1} END{exit !f}' <<< "$table" || die "no camera called '$c' (names are the bridge's: lowercase, dashes)"; done
  printf '%s\n' "${CAMS[@]}" > run/cams
}

# ---------------------------------------------------------------- sessions -----------------------------------
wait_session() {   # POST to the provisioner (that's what the player does on every start), then confirm the file
  say "5/7 Agora session"
  local c i code
  for c in "${CAMS[@]}"; do
    i=0
    while :; do
      code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:5051/provision/$c" 2>/dev/null)
      [ "$code" = 200 ] && [ -s "www/lake/$c.json" ] && break
      i=$((i+1)); [ $i -gt 12 ] && die "no session for $c (provisioner said HTTP ${code:-none}): docker compose logs lake-provisioner   (../WRITEUP.md section 8)"
      [ $i = 1 ] && printf '  waiting for the provisioner (needs the bridge login cache first)'; printf .; sleep 5
    done
    ok "$c: session file www/lake/$c.json (channel, key, RTC token; valid 1 h, renewed by the sidecar)"
  done
}

# ---------------------------------------------------------------- relay + decoders ---------------------------
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
start_mediamtx() {
  say "6/7 relay (mediamtx)"
  if alive run/mediamtx.pid; then ok "already running (pid $(cat run/mediamtx.pid))"; return; fi
  nohup mediamtx "$HERE/mediamtx.yml" >> logs/mediamtx.log 2>&1 &
  echo $! > run/mediamtx.pid
  sleep 1; alive run/mediamtx.pid || die "mediamtx exited: tail logs/mediamtx.log  (port $RTSP_PORT or $WEBRTC_PORT in use?)"
  ok "rtsp://127.0.0.1:$RTSP_PORT  +  http://localhost:$WEBRTC_PORT   (pid $(cat run/mediamtx.pid), log logs/mediamtx.log)"
}
cdp_port() { local i=0 c; while read -r c; do [ "$c" = "$1" ] && { echo $((CDP_BASE + i)); return; }; i=$((i+1)); done < run/cams; echo $((CDP_BASE + 90)); }
start_decoder() {   # one headless Chrome per camera (headless Chrome runs one page per process)
  local cam=$1 port; port=$(cdp_port "$cam")
  if alive "run/decoder-$cam.pid"; then ok "$cam: decoder already running (pid $(cat "run/decoder-$cam.pid"), cdp :$port)"; return; fi
  # Same flags as ../launchd/com.snakecam.coolcam.plist, as a plain background process with a pidfile.
  nohup "$CHROME" --headless=new "--user-data-dir=$HERE/run/chrome-$cam" --no-first-run --no-default-browser-check \
      --autoplay-policy=no-user-gesture-required --disable-background-timer-throttling --disable-renderer-backgrounding \
      --window-size=1920,1080 "--remote-debugging-port=$port" "--remote-allow-origins=http://localhost:$port" \
      "$PLAYER_BASE/lake.html?cam=$cam&res=$RES&codec=h265&whip=http://localhost:$WEBRTC_PORT/$cam/whip" \
      >> "logs/decoder-$cam.log" 2>&1 &
  echo $! > "run/decoder-$cam.pid"
  ok "$cam: headless Chrome decoding (pid $!, cdp :$port, log logs/decoder-$cam.log)"
}
start_decoders() { say "7/7 decoders"; CHROME=$(find_chrome) || die "no Chrome"; local c; for c in "${CAMS[@]}"; do start_decoder "$c"; done; }

# ---------------------------------------------------------------- proof --------------------------------------
grab_still() {   # grab_still <cam> : one JPEG from the RTSP relay, with a timeout (macOS has no `timeout`)
  local cam=$1 out="logs/$1.jpg" pid i
  ffmpeg -nostdin -loglevel error -y -rtsp_transport tcp -rw_timeout 15000000 -i "rtsp://127.0.0.1:$RTSP_PORT/$cam" -frames:v 1 "$out" >/dev/null 2>&1 & pid=$!
  i=0; while kill -0 $pid 2>/dev/null; do i=$((i+1)); [ $i -gt 25 ] && { kill $pid 2>/dev/null; break; }; sleep 1; done
  wait $pid 2>/dev/null; [ -s "$out" ]
}
prove() {
  say "proof"
  local c i
  for c in "${CAMS[@]}"; do
    printf '  %s: waiting for the camera to wake and the first frames to reach the relay (usually 20-60 s)' "$c"
    i=0
    until grab_still "$c"; do i=$((i+1)); [ $i -gt 8 ] && break; printf .; sleep 5; done; echo
    if [ -s "logs/$c.jpg" ]; then ok "$c: still saved to logs/$c.jpg ($(ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 "logs/$c.jpg" 2>/dev/null || echo 'jpeg'))"
    else warn "$c: no frame after ~3 min; './quickstream.sh status' shows what the decoder sees (../WRITEUP.md section 8)"; fi
  done
  echo
  say "your stream(s)"
  for c in "${CAMS[@]}"; do
    cat <<EOF
  $c
    RTSP            rtsp://$(hostname -s 2>/dev/null || hostname):$RTSP_PORT/$c     (rtsp://127.0.0.1:$RTSP_PORT/$c on this machine)
    WebRTC viewer   http://localhost:$WEBRTC_PORT/$c/                (any browser on this machine; LAN: use this host's IP)
    OBS             Sources > + > Media Source, untick "Local File", Input = the RTSP URL, Input Format = rtsp,
                    Reconnect Delay 2 s.  (Do NOT use a Browser Source on lake.html: OBS's browser cannot decode H.265.)
    VLC             File > Open Network > the RTSP URL
    Home Assistant  camera: - platform: generic   stream_source: rtsp://<this host>:$RTSP_PORT/$c   (or the go2rtc/WebRTC card)
EOF
  done
  echo "  Keep this machine awake. './quickstream.sh status' checks it, 'stop' ends it. Only ONE decoder per camera (one client per Agora session)."
}

# ---------------------------------------------------------------- status via CDP -----------------------------
cdp_eval() {   # cdp_eval <port> <js-expression>  -> value   (tiny websocket client, stdlib only)
  python3 - "$1" "$2" <<'PY'
import socket, os, base64, json, sys, struct, urllib.request
port, expr = int(sys.argv[1]), sys.argv[2]
pages = json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3))
page = next(p for p in pages if p.get("type") == "page")
path = page["webSocketDebuggerUrl"].split(f":{port}", 1)[1]
s = socket.create_connection(("127.0.0.1", port), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf: buf += s.recv(4096)
hdr, rest = buf.split(b"\r\n\r\n", 1)
assert b" 101 " in hdr.split(b"\r\n")[0], hdr
def send(txt):
    data = txt.encode(); mask = os.urandom(4); n = len(data); h = bytes([0x81])
    if n < 126: h += bytes([0x80 | n])
    elif n < 65536: h += bytes([0x80 | 126]) + struct.pack(">H", n)
    else: h += bytes([0x80 | 127]) + struct.pack(">Q", n)
    s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))
def take(n):
    global rest
    while len(rest) < n:
        c = s.recv(65536)
        if not c: raise EOFError
        rest += c
    out, rest = rest[:n], rest[n:]; return out
def recv():
    b1, b2 = take(2); n = b2 & 0x7f
    if n == 126: n = struct.unpack(">H", take(2))[0]
    elif n == 127: n = struct.unpack(">Q", take(8))[0]
    if b2 & 0x80: take(4)
    return take(n).decode()
send(json.dumps({"id": 1, "method": "Runtime.evaluate", "params": {"expression": expr, "returnByValue": True}}))
while True:
    m = json.loads(recv())
    if m.get("id") == 1: print(m["result"]["result"].get("value", "")); break
PY
}
PROBE='(()=>{const v=document.querySelector("video");const q=v&&v.getVideoPlaybackQuality?v.getVideoPlaybackQuality():null;return JSON.stringify({w:v?v.videoWidth:0,h:v?v.videoHeight:0,frames:q?q.totalVideoFrames:-1,whip:window.fpc?window.fpc.connectionState:"none",msg:document.getElementById("msg").textContent,last:(window.DBG||[]).slice(-2).join(" | ")})})()'
status() {
  say "status"
  if alive run/mediamtx.pid; then ok "mediamtx running (pid $(cat run/mediamtx.pid))"; else warn "mediamtx not running"; fi
  [ -f run/cams ] || { warn "no cameras chosen yet: run ./quickstream.sh"; return; }
  local c port a b fa fb
  while read -r c; do
    port=$(cdp_port "$c")
    if ! alive "run/decoder-$c.pid"; then warn "$c: decoder not running"; continue; fi
    if ! a=$(cdp_eval "$port" "$PROBE" 2>/dev/null) || [ -z "$a" ]; then warn "$c: decoder running (pid $(cat "run/decoder-$c.pid")) but CDP :$port not answering yet"; continue; fi
    sleep 2; b=$(cdp_eval "$port" "$PROBE" 2>/dev/null || echo "$a")
    fa=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["frames"])' "$a"); fb=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["frames"])' "$b")
    if [ "$fb" -gt "$fa" ] 2>/dev/null; then ok "$c: frames advancing ($fa -> $fb in 2 s)  $b"
    else warn "$c: frames NOT advancing ($fa -> $fb)  $b"; fi
  done < run/cams
}

# ---------------------------------------------------------------- stop ---------------------------------------
stop_all() {
  say "stop"
  local f c
  for f in run/decoder-*.pid; do
    [ -f "$f" ] || continue; c=${f#run/decoder-}; c=${c%.pid}
    if alive "$f"; then kill "$(cat "$f")" 2>/dev/null; ok "$c: decoder stopped"; else warn "$c: decoder was not running"; fi
    rm -f "$f"
  done
  if alive run/mediamtx.pid; then kill "$(cat run/mediamtx.pid)" 2>/dev/null; ok "mediamtx stopped"; else warn "mediamtx was not running"; fi
  rm -f run/mediamtx.pid
  echo "  containers still running (they only hold the login); './quickstream.sh down' stops them too"
}

# ---------------------------------------------------------------- main ---------------------------------------
cmd=${1:-start}; [ $# -gt 0 ] && shift
case "$cmd" in
  start)  check_tools; setup_wyze; start_containers; pick_cams "$@"; wait_session; start_mediamtx; start_decoders; prove;;
  login)  setup_wyze force; echo "  restart the containers to use it: docker compose up -d --force-recreate";;
  status) status;;
  stop)   stop_all;;
  down)   stop_all; docker compose down 2>&1 | sed 's/^/  /';;
  logs)   if [ -n "${1:-}" ]; then tail -n 40 -f "logs/decoder-$1.log"; else tail -n 40 -f logs/mediamtx.log logs/decoder-*.log; fi;;
  cams)   cam_table | column -t;;
  -h|--help|help) usage;;
  *) usage; exit 1;;
esac
