#!/bin/bash
# doctor.sh: checks every layer of the stream and prints PASS / WARN / FAIL with a one-line fix.
#   ./doctor.sh              ./doctor.sh --root DIR   (runtime root; default: this folder, $SNAKECAM_ROOT, or the parent of a kit/ folder)
#   ./doctor.sh --quick      skip the slow probes (RTSP frame grabs, frame-advance sampling)
# Read-only: it never restarts or changes anything. Exit code = number of FAILs.
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"; ROOT="${SNAKECAM_ROOT:-}"; QUICK=0
while [ $# -gt 0 ]; do case "$1" in --root) ROOT="$(cd "$2" && pwd)"; shift ;; --quick) QUICK=1 ;; -h|--help) sed -n 2,5p "$0"; exit 0 ;; *) echo "unknown option $1"; exit 2 ;; esac; shift; done
if [ -z "$ROOT" ]; then
  if [ ! -f "$KIT/.env" ] && [ "$(basename "$KIT")" = kit ] && [ -f "$KIT/../.env" ]; then ROOT="$(cd "$KIT/.." && pwd)"; else ROOT="$KIT"; fi
fi
ENV="$ROOT/.env"; OVERLAY="$ROOT/overlay"; CHATBOT="$ROOT/chatbot"; LOGS="$HOME/Library/Logs"
PY=/usr/bin/python3; [ -x "$CHATBOT/.venv/bin/python" ] && PY="$CHATBOT/.venv/bin/python"
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; N=; fi
NP=0; NW=0; NF=0
pass() { printf '%sPASS%s  %-34s %s\n' "$G" "$N" "$1" "${2:-}"; NP=$((NP+1)); }
warn() { printf '%sWARN%s  %-34s %s\n' "$Y" "$N" "$1" "${2:-}"; [ -n "${3:-}" ] && printf '      %sfix:%s %s\n' "$B" "$N" "$3"; NW=$((NW+1)); }
fail() { printf '%sFAIL%s  %-34s %s\n' "$R" "$N" "$1" "${2:-}"; [ -n "${3:-}" ] && printf '      %sfix:%s %s\n' "$B" "$N" "$3"; NF=$((NF+1)); }
head_() { printf '\n%s%s-- %s%s\n' "$B" "$C" "$*" "$N"; }
envget() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^"//' -e 's/"$//' -e 's/[[:space:]]*$//'; }
port() { nc -z -w1 127.0.0.1 "$1" >/dev/null 2>&1; }
loaded() { launchctl list 2>/dev/null | grep -q "[[:space:]]$1\$"; }
age() { echo $(( $(date +%s) - $(stat -f %m "$1" 2>/dev/null || echo 0) )); }
CAM_COLD="$(envget CAM_COLD)"; CHAN="$(envget TWITCH_CHANNEL)"; CID="$(envget TWITCH_CLIENT_ID)"
LOAD="launchctl load ~/Library/LaunchAgents/com.snakecam"

printf '%sClaudeWyze4Sln doctor%s   root: %s   %s\n' "$B" "$N" "$ROOT" "$(date '+%Y-%m-%d %H:%M:%S')"
[ -f "$ENV" ] || { fail ".env" "missing at $ENV" "./install.sh"; }

# ---- 1. Docker + bridge ---------------------------------------------------------------------------------
head_ "Docker VM, Wyze bridge, provisioner"
if command -v colima >/dev/null && colima status >/dev/null 2>&1; then pass "Colima" "running"; else fail "Colima" "not running" "colima start   (and: brew services start colima)"; fi
for c in wyze-bridge lake-provisioner; do
  st="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)"
  if [ "$st" = running ]; then pass "container $c" "running"; else fail "container $c" "${st:-absent}" "cd $ROOT && docker compose up -d"; fi
done
API="$($PY - <<'PY' 2>/dev/null
import json,urllib.request
try:
    d=json.load(urllib.request.urlopen("http://localhost:5050/api",timeout=8)); cams=d.get("cameras",d)
    cams={n:c for n,c in cams.items() if isinstance(c,dict)}
    print(len(cams), ", ".join(f"{n} ({c.get('product_model','?')})" for n,c in cams.items()))
except Exception as e: print("ERR", e)
PY
)"
case "$API" in
  ERR*) fail "bridge API :5050/api" "$API" "cd $ROOT && docker compose logs --tail 40 wyze-bridge" ;;
  0*) fail "bridge API :5050/api" "no cameras" "check the Wyze app; cd $ROOT && docker compose restart wyze-bridge" ;;
  *) pass "bridge API :5050/api" "${API#* }" ;;
esac
if [ "$(envget CAM_COLD_PATH)" = kvs ]; then pass "provisioner session" "not needed (CAM_COLD_PATH=kvs)"
elif [ -n "$CAM_COLD" ] && [ -f "$OVERLAY/lake/$CAM_COLD.json" ]; then
  a=$(age "$OVERLAY/lake/$CAM_COLD.json")
  if [ "$a" -lt 3600 ]; then pass "provisioner session" "$CAM_COLD.json is $((a/60)) min old (renews every 45 min)"
  else warn "provisioner session" "$CAM_COLD.json is $((a/60)) min old; the token lives 60 min" "cd $ROOT && docker compose logs --tail 20 lake-provisioner && docker compose restart lake-provisioner"; fi
else fail "provisioner session" "no overlay/lake/${CAM_COLD:-?}.json" "cd $ROOT && docker compose logs --tail 20 lake-provisioner"; fi
if [ -s "$OVERLAY/agora-rtc-sdk.js" ]; then pass "Agora SDK" "overlay/agora-rtc-sdk.js"; else fail "Agora SDK" "overlay/agora-rtc-sdk.js missing" "cd $KIT/players && ./get-agora-sdk.sh && cp agora-rtc-sdk.js $OVERLAY/"; fi

# ---- 2. Relay + decoders --------------------------------------------------------------------------------
head_ "Relay (mediamtx) and the two headless-Chrome decoders"
if loaded com.snakecam.relay; then pass "relay agent" "loaded"; else fail "relay agent" "com.snakecam.relay not loaded" "$LOAD.relay.plist"; fi
for p in 8555:RTSP 8890:WHIP; do if port "${p%%:*}"; then pass "relay port ${p%%:*} (${p#*:})" "open"; else fail "relay port ${p%%:*} (${p#*:})" "closed" "tail -20 $LOGS/snakecam-relay.log"; fi; done
for cam in hotcam:9225 coolcam:9224; do
  a=${cam%%:*}; dp=${cam#*:}
  if loaded com.snakecam.$a; then pass "$a agent" "loaded"; else fail "$a agent" "com.snakecam.$a not loaded" "$LOAD.$a.plist"; continue; fi
  if ! port "$dp"; then fail "$a debug port $dp" "not answering (Chrome not up?)" "tail -20 $LOGS/snakecam-$a.log"; continue; fi
  if [ $QUICK = 1 ]; then pass "$a debug port $dp" "answering"; continue; fi
  R="$($PY - "$dp" <<'PY' 2>&1
import json,sys,time,urllib.request
port=sys.argv[1]
try: import websocket
except ImportError: print("NOWS"); raise SystemExit
try:
    pages=[p for p in json.load(urllib.request.urlopen(f"http://127.0.0.1:{port}/json",timeout=5)) if "snakecam" in p.get("url","")]
    if not pages: print("NOPAGE"); raise SystemExit
    ws=websocket.create_connection(pages[0]["webSocketDebuggerUrl"],origin=f"http://localhost:{port}",timeout=10)
    def ev(i):
        e="(()=>{const v=document.querySelector('video');if(!v)return null;const q=v.getVideoPlaybackQuality();return {f:q.totalVideoFrames,w:v.videoWidth,h:v.videoHeight,d:(window.DBG||[]).slice(-1)[0]||''}})()"
        ws.send(json.dumps({"id":i,"method":"Runtime.evaluate","params":{"expression":e,"returnByValue":True}}))
        while True:
            m=json.loads(ws.recv())
            if m.get("id")==i: return m["result"]["result"].get("value")
    a=ev(1); time.sleep(2); b=ev(2); ws.close()
    if not a or not b: print("NOVIDEO"); raise SystemExit
    print("OK" if b["f"]>a["f"] else "STALL", b["f"]-a["f"], f"{b['w']}x{b['h']}", b["d"])
except Exception as e: print("ERR", e)
PY
)"
  case "$R" in
    OK*) set -- $R; pass "$a frames advancing" "+$2 frames in 2 s, $3 ${4:+(last log: ${*:4})}" ;;
    STALL*) set -- $R; fail "$a frames advancing" "video frozen at $3 (${*:4})" "launchctl kickstart -k gui/$(id -u)/com.snakecam.$a   (the page also reboots the camera itself after 3 stalls)" ;;
    NOWS) warn "$a frames advancing" "python websocket-client missing; skipped" "$CHATBOT/.venv/bin/python -m pip install websocket-client" ;;
    NOPAGE) fail "$a frames advancing" "Chrome is up but not on the player page" "tail -20 $LOGS/snakecam-$a.log" ;;
    NOVIDEO) fail "$a frames advancing" "player page has no <video> yet (camera not connected)" "tail -30 $LOGS/snakecam-$a.log; open http://localhost:5050" ;;
    *) warn "$a frames advancing" "$R" ;;
  esac
done
if [ $QUICK = 0 ] && command -v ffmpeg >/dev/null; then
  for a in hotcam coolcam; do
    if ffmpeg -v error -timeout 10000000 -rtsp_transport tcp -i "rtsp://127.0.0.1:8555/$a" -frames:v 1 -f null - </dev/null >/dev/null 2>&1; then pass "RTSP frame grab $a" "rtsp://127.0.0.1:8555/$a decodes"
    else fail "RTSP frame grab $a" "no frame from rtsp://127.0.0.1:8555/$a within 10 s" "tail -20 $LOGS/snakecam-$a.log $LOGS/snakecam-relay.log"; fi
  done
fi

# ---- 3. Sensors -----------------------------------------------------------------------------------------
head_ "Sensors (Govee hub on :5090)"
if loaded com.snakecam.sensors; then pass "sensors agent" "loaded"; else warn "sensors agent" "com.snakecam.sensors not loaded" "$LOAD.sensors.plist   (needs sensors/build.sh + SENSOR_HOT/COOL in .env)"; fi
S="$($PY - <<'PY' 2>/dev/null
import json,time,urllib.request
try:
    d=json.load(urllib.request.urlopen("http://127.0.0.1:5090/state.json",timeout=5)); now=time.time()
    parts=[]; bad=0
    for k in ("hot","cool"):
        r=d.get(k)
        if r: parts.append(f"{k} {r.get('f')}F/{r.get('rh')}% ({int(now-r['seen'])}s ago)")
        else: parts.append(f"{k} NONE"); bad+=1
    print("OK" if bad==0 and now-d.get("updated",0)<120 else "STALE", int(now-d.get("updated",0)), "; ".join(parts))
except Exception as e: print("ERR", e)
PY
)"
case "$S" in
  OK*) pass "sensor readings" "${S#OK * }" ;;
  STALE*) warn "sensor readings" "${S#STALE * }" "sensor out of range / battery? tail -5 $LOGS/snakecam-sensors.log; SENSOR_HOT/COOL names in .env must match govee_scan.py" ;;
  *) fail "sensor hub :5090/state.json" "$S" "$LOAD.sensors.plist; tail -20 $LOGS/snakecam-sensors.log" ;;
esac

# ---- 4. OBS + Twitch ------------------------------------------------------------------------------------
head_ "OBS and Twitch"
if pgrep -xq OBS; then pass "OBS process" "running$(loaded com.snakecam.obs || echo ' (but the launchd agent is NOT loaded)')"; else fail "OBS process" "not running" "$LOAD.obs.plist"; fi
O="$(SNAKECAM_ENV="$ROOT/.env" $PY - <<'PY' 2>&1
import json
try: import websocket
except ImportError: print("NOWS"); raise SystemExit
try:
    import base64,hashlib,os,re
    pw=""
    for l in open(os.environ["SNAKECAM_ENV"]):
        m=re.match(r'\s*OBS_WS_PASSWORD=\s*"?([^"#]*)',l)
        if m: pw=m.group(1).strip()
    ws=websocket.create_connection("ws://127.0.0.1:4455",timeout=8); hello=json.loads(ws.recv()); auth=(hello.get("d") or {}).get("authentication"); ident={"rpcVersion":1}
    if auth:
        secret=base64.b64encode(hashlib.sha256((pw+auth["salt"]).encode()).digest()).decode()
        ident["authentication"]=base64.b64encode(hashlib.sha256((secret+auth["challenge"]).encode()).digest()).decode()
    ws.send(json.dumps({"op":1,"d":ident}))
    if json.loads(ws.recv()).get("op")!=2: print("obs-websocket rejected the password (OBS_WS_PASSWORD in .env)"); raise SystemExit
    def req(t,i):
        ws.send(json.dumps({"op":6,"d":{"requestType":t,"requestId":str(i),"requestData":{}}}))
        while True:
            m=json.loads(ws.recv())
            if m["op"]==7 and m["d"]["requestId"]==str(i): return m["d"].get("responseData") or {}
    s=req("GetStreamStatus",1); st=req("GetStats",2); ws.close()
    print("LIVE" if s.get("outputActive") else "IDLE", f"{int(s.get('outputDuration',0)/60000)} min, {s.get('outputSkippedFrames',0)}/{s.get('outputTotalFrames',0)} frames skipped, {st.get('activeFps',0):.0f} fps")
except Exception as e: print("ERR", e)
PY
)"
case "$O" in
  LIVE*) pass "OBS streaming (obs-websocket :4455)" "${O#LIVE }" ;;
  IDLE*) fail "OBS streaming (obs-websocket :4455)" "OBS is up but not streaming" "OBS > Start Streaming (the agent passes --startstreaming; check the stream key: Settings > Stream)" ;;
  NOWS) warn "OBS streaming" "python websocket-client missing; skipped" "$CHATBOT/.venv/bin/python -m pip install websocket-client" ;;
  *) fail "obs-websocket :4455" "$O" "OBS > Tools > WebSocket Server Settings > Enable, port 4455, password = OBS_WS_PASSWORD from .env (obs/install-obs-config.sh writes this when OBS is closed)" ;;
esac
T="$($PY - "$CHATBOT/token.json" "$CID" "$CHAN" <<'PY' 2>&1
import json,sys,time,urllib.request,urllib.parse
tf,cid,chan=sys.argv[1:4]
try: tok=json.load(open(tf))["access_token"]
except Exception: print("NOTOKEN"); raise SystemExit
try:
    v=json.load(urllib.request.urlopen(urllib.request.Request("https://id.twitch.tv/oauth2/validate",headers={"Authorization":"OAuth "+tok}),timeout=15))
    print("VALID", v.get("login"), v.get("expires_in",0)//60, ",".join(sorted(v.get("scopes",[]))))
except Exception as e: print("INVALID", e); raise SystemExit
try:
    r=json.load(urllib.request.urlopen(urllib.request.Request("https://api.twitch.tv/helix/streams?user_login="+urllib.parse.quote(chan),headers={"Client-Id":cid,"Authorization":"Bearer "+tok}),timeout=15))
    d=r.get("data",[])
    print("LIVE" if d else "OFFLINE", (f"{d[0].get('viewer_count')} viewers, since {d[0].get('started_at')}" if d else ""))
except Exception as e: print("HELIXERR", e)
PY
)"
L1="$(echo "$T" | sed -n 1p)"; L2="$(echo "$T" | sed -n 2p)"
case "$L1" in
  VALID*) set -- $L1; login=$2; mins=$3; scopes=$4
    miss=""; for s in chat:read chat:edit moderator:read:followers; do echo "$scopes" | grep -q "$s" || miss="$miss $s"; done
    if [ -z "$miss" ]; then pass "bot token (validate)" "$login, ${scopes//,/ }; expires in $mins min (the bot refreshes it)"
    else warn "bot token (validate)" "$login is missing scopes:$miss" "$CHATBOT/.venv/bin/python $CHATBOT/auth.py"; fi ;;
  NOTOKEN) warn "bot token" "no chatbot/token.json (bot + watchdog off)" "$CHATBOT/.venv/bin/python $CHATBOT/auth.py" ;;
  *) fail "bot token (validate)" "$L1" "$CHATBOT/.venv/bin/python $CHATBOT/auth.py" ;;
esac
case "$L2" in
  LIVE*) pass "Twitch says #$CHAN is" "LIVE (${L2#LIVE })" ;;
  OFFLINE*) fail "Twitch says #$CHAN is" "OFFLINE" "if OBS reports streaming: check the stream key, wait 60 s; the watchdog restarts the output after 3 min" ;;
  HELIXERR*) warn "Twitch live status" "${L2#HELIXERR }" "TWITCH_CLIENT_ID/TWITCH_CHANNEL in .env; network" ;;
esac

# ---- 5. Bot + watchdog ----------------------------------------------------------------------------------
head_ "Chat bot and watchdog"
for a in chatbot watchdog; do
  if loaded com.snakecam.$a; then
    f="$LOGS/snakecam-$a.log"; ag=$(age "$f")
    if [ "$ag" -lt 600 ]; then pass "$a" "loaded; log written $((ag/60)) min ago"
    elif [ $a = watchdog ]; then pass "$a" "loaded; quiet for $((ag/60)) min (it only logs problems)"
    else warn "$a" "loaded but no log line for $((ag/60)) min" "tail -20 $f   (the bot logs at least once an hour; connection trouble shows here)"; fi
    if [ $a = chatbot ] && tail -50 "$f" 2>/dev/null | grep -qiE "claude cli error|Traceback"; then warn "$a errors" "recent 'claude cli error' / Traceback in the log" "tail -30 $f"; fi
  else warn "$a" "com.snakecam.$a not loaded" "$LOAD.$a.plist   (needs chatbot/token.json)"; fi
done
case "$(envget CLEOBOT_LLM_BACKEND)" in
  cli) if command -v claude >/dev/null && claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; then pass "Claude backend" "cli, signed in"; else fail "Claude backend" "cli but the claude command is missing or signed out" "run: claude   (sign in), or set CLEOBOT_LLM_BACKEND=api/off"; fi ;;
  api) [ -n "$(envget ANTHROPIC_API_KEY)" ] && pass "Claude backend" "api key set" || fail "Claude backend" "api but no ANTHROPIC_API_KEY" "$CHATBOT/set-claude-key.sh" ;;
  off) warn "Claude backend" "off (templates only)" "CLEOBOT_LLM_BACKEND=cli in .env" ;;
  *) warn "Claude backend" "CLEOBOT_LLM_BACKEND unset" "./install.sh" ;;
esac

# ---- 6. Machine -----------------------------------------------------------------------------------------
head_ "This Mac"
avail=$(df -g / | awk 'NR==2{print $4}')
if [ "$avail" -ge 20 ]; then pass "disk space" "${avail} GB free on /"; elif [ "$avail" -ge 5 ]; then warn "disk space" "${avail} GB free on /" "OBS logs + Chrome profiles grow; clear ~/Library/Logs/snakecam-*.log"; else fail "disk space" "${avail} GB free on /" "free space now: rm ~/Library/Logs/snakecam-*.log; docker system prune"; fi
AUTOL="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ "$AUTOL" = "$(id -un)" ]; then pass "auto-login" "$AUTOL"; else warn "auto-login" "${AUTOL:-off} (after a reboot nothing starts until someone logs in)" "System Settings > Users & Groups > Automatically log in as: $(id -un)  (FileVault must be off)"; fi
if pmset -g 2>/dev/null | grep -qE "^\s*sleep\s+0"; then pass "system sleep" "off"; else fail "system sleep" "enabled" "System Settings > Energy > Prevent automatic sleeping (or: sudo pmset -a sleep 0)"; fi
pmset -g 2>/dev/null | grep -qE "^\s*autorestart\s+1" && pass "restart after power failure" "on" || warn "restart after power failure" "off" "System Settings > Energy > Start up automatically after a power failure (or: sudo pmset -a autorestart 1)"

printf '\n%s%d PASS, %d WARN, %d FAIL%s\n' "$B" "$NP" "$NW" "$NF" "$N"
exit $NF
