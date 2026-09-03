#!/bin/bash
# ClaudeWyze4Sln installer: a blank Mac (Apple silicon) to a live 24/7 Twitch animal cam.
#
#   ./install.sh            walk through every step, skipping what is already done
#   ./install.sh --check    report what each step would do; change nothing
#   ./install.sh --yes      non-interactive where possible (steps that need you are left as TODO)
#   ./install.sh --root DIR runtime root (where .env, overlay/, tokens/, logs/ live); default: this folder
#                           (also $SNAKECAM_ROOT; if this kit sits in a live install's kit/ folder, the parent is used)
#
# Idempotent: re-run it any time. Every failure ends with the exact command that fixes it.
# Four things only you can do: the Wyze API key pair, the Twitch developer app, the Twitch stream key,
# and two device-code approvals (Twitch bot login, Claude CLI login). See QUICKSTART.md.
set -u

KIT="$(cd "$(dirname "$0")" && pwd)"
ROOT="${SNAKECAM_ROOT:-}"
CHECK=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK=1 ;;
    --yes|-y) YES=1 ;;
    --root) ROOT="$(cd "$2" && pwd)"; shift ;;
    -h|--help) sed -n 2,14p "$0"; exit 0 ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac; shift
done
if [ -z "$ROOT" ]; then
  if [ ! -f "$KIT/.env" ] && [ "$(basename "$KIT")" = kit ] && [ -f "$KIT/../.env" ] && [ -f "$KIT/../docker-compose.yml" ]; then
    ROOT="$(cd "$KIT/.." && pwd)"          # the kit lives inside a live install
  else
    ROOT="$KIT"
  fi
fi
ENV="$ROOT/.env"; OVERLAY="$ROOT/overlay"; CHATBOT="$ROOT/chatbot"; VENV="$CHATBOT/.venv"
OBSDIR="$HOME/Library/Application Support/obs-studio"
AGENTS="$HOME/Library/LaunchAgents"
PY=/usr/bin/python3
PIP_VENV="websocket-client anthropic"

# ---- output ---------------------------------------------------------------------------------------------
if [ -t 1 ]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'; else B=; G=; Y=; R=; C=; D=; N=; fi
NDONE=0; NTODO=0; NFAIL=0
step()  { printf '\n%s%s==> %s%s\n' "$B" "$C" "$*" "$N"; }
done_() { printf '  %s[done]%s %s\n' "$G" "$N" "$*"; NDONE=$((NDONE+1)); }
todo()  { printf '  %s[todo]%s %s\n' "$Y" "$N" "$*"; NTODO=$((NTODO+1)); }
info()  { printf '  %s%s%s\n' "$D" "$*" "$N"; }
warn()  { printf '  %s[warn]%s %s\n' "$Y" "$N" "$*"; }
fail()  { printf '  %s[FAIL]%s %s\n' "$R" "$N" "$*"; NFAIL=$((NFAIL+1)); }
fix()   { printf '         %sfix:%s %s\n' "$B" "$N" "$*"; }
die()   { fail "$1"; [ -n "${2:-}" ] && fix "$2"; printf '\n%sStopped.%s Fix the above and run ./install.sh again; finished steps are skipped.\n' "$R" "$N"; exit 1; }
ask()   { # ask VAR "prompt" [default]  -> sets VAR; in --yes mode uses the default
  local __v="$1" __p="$2" __d="${3:-}" __in
  if [ $YES = 1 ]; then eval "$__v=\"\$__d\""; return; fi
  if [ -n "$__d" ]; then read -r -p "  $__p [$__d]: " __in; else read -r -p "  $__p: " __in; fi
  eval "$__v=\"\${__in:-\$__d}\""
}
pause() { [ $YES = 1 ] && return 1; read -r -p "  $1 (press Enter when done, or 's' to skip): " a; [ "$a" != s ]; }
has()   { command -v "$1" >/dev/null 2>&1; }
port()  { nc -z -w1 127.0.0.1 "$1" >/dev/null 2>&1; }
envget() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^"//' -e 's/"$//' -e 's/[[:space:]]*$//'; }
envset() { # envset KEY VALUE  (keeps a trailing comment, appends if missing; never echoes the value)
  [ $CHECK = 1 ] && { info "would set $1 in .env"; return; }
  $PY - "$ENV" "$1" "$2" <<'PY'
import sys,re
p,k,v=sys.argv[1:4]; lines=open(p).read().split("\n"); out=[]; hit=False
for l in lines:
    if re.match(r"^#?\s*"+re.escape(k)+r"=",l):
        if hit: continue
        c=""; m=re.search(r"\s+#.*$",l.split("=",1)[1]); c=m.group(0) if m else ""
        out.append(f"{k}={v}{c}"); hit=True
    else: out.append(l)
if not hit:
    if out and out[-1]=="": out.pop()
    out.append(f"{k}={v}"); out.append("")
open(p,"w").write("\n".join(out))
PY
}
loaded() { launchctl list 2>/dev/null | grep -q "[[:space:]]$1\$"; }

printf '%sClaudeWyze4Sln installer%s\n' "$B" "$N"
info "kit: $KIT"; info "runtime root: $ROOT"
[ $CHECK = 1 ] && info "check mode: nothing will be changed"

# =========================================================================================================
step "0. Preflight: macOS, Xcode tools, Homebrew, packages"
[ "$(uname -s)" = Darwin ] || die "this kit is for macOS (launchd, Chrome path, OBS config are Mac-specific)"
[ "$(uname -m)" = arm64 ] || warn "not Apple silicon ($(uname -m)); Homebrew paths below assume /opt/homebrew"
done_ "macOS $(sw_vers -productVersion) on $(uname -m)"

if xcode-select -p >/dev/null 2>&1; then done_ "Xcode command line tools ($(xcode-select -p))"
else todo "Xcode command line tools"; [ $CHECK = 1 ] || die "Xcode command line tools are missing (needed for cc, git, python)" "xcode-select --install   # click Install, wait, then re-run ./install.sh"; fi

if has brew; then
  BREWDIR="$(brew --prefix)"; OWNER="$(stat -f %Su "$BREWDIR")"
  if [ "$OWNER" != "$(id -un)" ]; then
    if [ -w "$BREWDIR/Cellar" ] && [ -w "$BREWDIR/bin" ]; then
      done_ "Homebrew at $BREWDIR (owned by '$OWNER', but writable by you; ok)"
    else
      fail "Homebrew at $BREWDIR is owned by '$OWNER' and you ($(id -un)) cannot write to it"
      fix "log in as '$OWNER' and run:  sudo chown -R $(id -un):admin $BREWDIR   (or give your user the admin group and: sudo chmod -R g+w $BREWDIR)"
      [ $CHECK = 1 ] || exit 1
    fi
  else done_ "Homebrew at $BREWDIR"; fi
else
  todo "Homebrew"
  [ $CHECK = 1 ] || die "Homebrew is not installed" '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"   then: eval "$(/opt/homebrew/bin/brew shellenv)" and re-run ./install.sh'
fi

if has brew; then
  MISSING=""
  for f in colima docker docker-compose mediamtx ffmpeg python@3.12 gh; do
    case $f in python@3.12) has python3.12 && continue ;; *) has "$f" && continue ;; esac
    brew list --formula "$f" >/dev/null 2>&1 || MISSING="$MISSING $f"
  done
  if [ -z "$MISSING" ]; then done_ "brew formulae: colima docker docker-compose mediamtx ffmpeg python@3.12 gh"
  else
    todo "brew formulae missing:$MISSING"
    # shellcheck disable=SC2086
    [ $CHECK = 1 ] || { brew install $MISSING || die "brew install failed" "brew install$MISSING"; }
  fi
  if [ -d "/Applications/Google Chrome.app" ]; then done_ "Google Chrome"
  else todo "Google Chrome (H.265 in WebRTC needs Chrome 130+)"; [ $CHECK = 1 ] || { brew install --cask google-chrome || die "Chrome install failed" "brew install --cask google-chrome"; }; fi
  if [ -d /Applications/OBS.app ]; then done_ "OBS Studio"
  else todo "OBS Studio"; [ $CHECK = 1 ] || { brew install --cask obs || die "OBS install failed" "brew install --cask obs"; }; fi
fi

# a runtime root other than the kit gets the code folders linked in (chatbot/, obs/, sensors/, relay/, lake/)
if [ "$ROOT" != "$KIT" ]; then for d in chatbot obs sensors relay lake; do
  [ -e "$ROOT/$d" ] || { if [ $CHECK = 1 ]; then info "would link $d/ -> kit"; else ln -s "$KIT/$d" "$ROOT/$d"; fi; }
done; fi
if [ -x "$VENV/bin/python" ] && "$VENV/bin/python" -c "import websocket" 2>/dev/null; then done_ "python venv $VENV (websocket-client)"
else
  todo "python venv for the bot/watchdog: $VENV"
  if [ $CHECK = 0 ]; then
    PY312="$(command -v python3.12 || echo "$(brew --prefix 2>/dev/null)/bin/python3.12")"
    [ -x "$PY312" ] || die "python3.12 not found" "brew install python@3.12"
    mkdir -p "$CHATBOT"; [ -d "$CHATBOT" ] || die "no chatbot folder at $CHATBOT"
    "$PY312" -m venv "$VENV" && "$VENV/bin/python" -m pip install -q --upgrade pip && "$VENV/bin/python" -m pip install -q $PIP_VENV \
      || die "venv setup failed" "$PY312 -m venv $VENV && $VENV/bin/python -m pip install $PIP_VENV"
    done_ "python venv created"
  fi
fi
if $PY -c "import bleak" 2>/dev/null; then done_ "bleak for /usr/bin/python3 (the Bluetooth sensor reader)"
else
  todo "bleak (Bluetooth) for /usr/bin/python3"
  [ $CHECK = 1 ] || { $PY -m pip install -q --user bleak || die "pip install bleak failed" "/usr/bin/python3 -m pip install --user bleak"; }
fi

# =========================================================================================================
step "1. Runtime layout at $ROOT (.env, docker-compose.yml, overlay/, tokens/, logs/)"
if [ -f "$ENV" ]; then done_ ".env exists"
else todo ".env from bridge/.env.example"; [ $CHECK = 1 ] || { cp "$KIT/bridge/.env.example" "$ENV" && chmod 600 "$ENV"; }; fi
if [ -f "$ROOT/docker-compose.yml" ]; then done_ "docker-compose.yml"
else todo "docker-compose.yml (copy of bridge/docker-compose.yml)"; [ $CHECK = 1 ] || cp "$KIT/bridge/docker-compose.yml" "$ROOT/docker-compose.yml"; fi
NEED=""
for f in cam.html lake.html; do [ -f "$OVERLAY/$f" ] || NEED="$NEED players/$f"; done
for f in overlay.html ambience.html facts.json tarot-deck.json; do [ -f "$OVERLAY/$f" ] || NEED="$NEED overlay-example/$f"; done
[ -d "$OVERLAY/tarot" ] || NEED="$NEED overlay-example/tarot/"
if [ -z "$NEED" ]; then done_ "overlay/ (players + overlay pages; the bridge serves it at :5050/static/snakecam/)"
else
  todo "overlay/ needs:$NEED"
  if [ $CHECK = 0 ]; then
    mkdir -p "$OVERLAY/lake" "$ROOT/tokens" "$ROOT/logs"
    for f in cam.html lake.html; do [ -f "$OVERLAY/$f" ] || cp "$KIT/players/$f" "$OVERLAY/"; done
    for f in overlay.html ambience.html facts.json tarot-deck.json; do [ -f "$OVERLAY/$f" ] || cp "$KIT/overlay-example/$f" "$OVERLAY/"; done
    [ -d "$OVERLAY/tarot" ] || cp -R "$KIT/overlay-example/tarot" "$OVERLAY/"
    done_ "overlay/ populated (your copies; edit freely, the kit's originals stay in players/ and overlay-example/)"
  fi
fi
[ $CHECK = 1 ] || mkdir -p "$OVERLAY/lake" "$ROOT/tokens" "$ROOT/logs" "$CHATBOT/cli-workdir"

# =========================================================================================================
step "2. Wyze credentials (login + API key pair)"
if [ -n "$(envget WYZE_EMAIL)" ] && [ "$(envget WYZE_EMAIL)" != you@example.com ] && [ -n "$(envget WYZE_PASSWORD)" ] && [ -n "$(envget WYZE_API_ID)" ] && [ -n "$(envget WYZE_API_KEY)" ]; then
  done_ "WYZE_EMAIL / WYZE_PASSWORD / WYZE_API_ID / WYZE_API_KEY are set in .env"
else
  todo "Wyze login + API key pair in .env"
  info "YOU: create a key pair at https://developer-api-console.wyze.com/ (Wyze account > Create API key)."
  if [ $CHECK = 0 ]; then
    [ $YES = 1 ] && die "Wyze credentials are missing and --yes cannot type them" "SNAKECAM_ROOT=$ROOT $KIT/bridge/setup-wyze.sh   (writes them into .env)"
    SNAKECAM_ROOT="$ROOT" bash "$KIT/bridge/setup-wyze.sh" || die "credentials not saved" "SNAKECAM_ROOT=$ROOT $KIT/bridge/setup-wyze.sh"
  fi
fi

# =========================================================================================================
step "3. Docker VM (Colima) + Wyze bridge + Pan V4 provisioner"
if has colima && colima status >/dev/null 2>&1; then done_ "Colima is running"
else
  todo "colima start (first start downloads a ~600 MB VM image)"
  [ $CHECK = 1 ] || { colima start || die "Colima did not start" "colima start   (then ./install.sh again)"; }
fi
if has brew && brew services list 2>/dev/null | grep -qE "^colima[[:space:]]+started"; then done_ "Colima starts at login (brew services)"
else todo "brew services start colima (so Docker comes back after a reboot)"; [ $CHECK = 1 ] || brew services start colima >/dev/null 2>&1 || warn "brew services start colima failed; Docker will not survive a reboot"; fi
up() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null | grep -q running; }
if up wyze-bridge && up lake-provisioner; then done_ "containers wyze-bridge + lake-provisioner are running"
else
  todo "docker compose up -d (wyze-bridge + lake-provisioner)"
  [ $CHECK = 1 ] || { ( cd "$ROOT" && docker compose up -d ) || die "docker compose failed" "cd $ROOT && docker compose up -d && docker compose logs --tail 20"; }
fi
if port 5050; then done_ "bridge web UI answering on http://localhost:5050"
else
  todo "wait for the bridge on :5050"
  if [ $CHECK = 0 ]; then
    printf '  waiting for the bridge to log in to Wyze'; for _ in $(seq 1 60); do port 5050 && break; printf .; sleep 2; done; echo
    port 5050 || die "the bridge never came up on :5050" "cd $ROOT && docker compose logs --tail 40 wyze-bridge   (wrong password / key pair is the usual cause; fix with bridge/setup-wyze.sh, then docker compose up -d --force-recreate)"
  fi
fi

# =========================================================================================================
step "4. Cameras: which is the hot side, which is the cool side"
discover() { $PY - <<'PY'
import json,urllib.request
try: d=json.load(urllib.request.urlopen("http://localhost:5050/api",timeout=8)); cams=d.get("cameras",d)
except Exception: raise SystemExit(1)
for n,c in cams.items():
    if isinstance(c,dict): print(n, c.get("product_model","?"), {"HL_PAN4":"Pan-V4(lake/Agora)","HL_PAN3":"Pan-V3(Kinesis)"}.get(c.get("product_model"),"(Kinesis)"))
PY
}
CAM_HOT="$(envget CAM_HOT)"; CAM_COLD="$(envget CAM_COLD)"
if [ -n "$CAM_HOT" ] && [ -n "$CAM_COLD" ] && [ "$CAM_HOT" != hot-side ]; then
  done_ "CAM_HOT=$CAM_HOT  CAM_COLD=$CAM_COLD"
else
  todo "pick CAM_HOT / CAM_COLD from the cameras the bridge found"
  if [ $CHECK = 0 ]; then
    LIST="$(discover)" || die "the bridge API did not list any cameras" "open http://localhost:5050  and  cd $ROOT && docker compose logs --tail 40 wyze-bridge"
    [ -n "$LIST" ] || die "the bridge found no cameras on your Wyze account" "add the cameras in the Wyze app first, then: cd $ROOT && docker compose restart wyze-bridge"
    echo "$LIST" | awk '{printf "    %d) %-22s %-10s %s\n", NR, $1, $2, $3}'
    [ $YES = 1 ] && die "cannot choose cameras non-interactively" "run ./install.sh without --yes, or put CAM_HOT= and CAM_COLD= into $ENV"
    N="$(echo "$LIST" | wc -l | tr -d ' ')"
    ask H "number of the HOT side camera" 1; ask K "number of the COOL side camera" "$([ "$N" -ge 2 ] && echo 2 || echo 1)"
    CAM_HOT="$(echo "$LIST" | sed -n "${H}p" | awk '{print $1}')"; CAM_COLD="$(echo "$LIST" | sed -n "${K}p" | awk '{print $1}')"
    [ -n "$CAM_HOT" ] && [ -n "$CAM_COLD" ] || die "bad choice" "./install.sh"
    envset CAM_HOT "$CAM_HOT"; envset CAM_COLD "$CAM_COLD"; done_ "CAM_HOT=$CAM_HOT  CAM_COLD=$CAM_COLD written to .env"
  fi
fi

# =========================================================================================================
step "5. Pan V4 ('lake' / Agora) session for the cool camera"
COLD_PATH="$(envget CAM_COLD_PATH)"
if [ -n "$CAM_COLD" ] && [ -f "$OVERLAY/lake/$CAM_COLD.json" ]; then
  AGE=$(( $(date +%s) - $(stat -f %m "$OVERLAY/lake/$CAM_COLD.json") ))
  done_ "provisioner wrote overlay/lake/$CAM_COLD.json ($((AGE/60)) min ago; renewed every 45 min)"
  [ "$COLD_PATH" = lake ] || envset CAM_COLD_PATH lake
elif [ "$COLD_PATH" = kvs ]; then
  done_ "cool camera uses the Kinesis path (CAM_COLD_PATH=kvs); no lake session needed"
elif [ -z "$CAM_COLD" ]; then
  todo "needs the camera choice from step 4"
else
  MODEL="$(discover 2>/dev/null | awk -v c="$CAM_COLD" '$1==c{print $2}')"
  if [ "$MODEL" = HL_PAN4 ] || [ "$MODEL" = "" ]; then
    todo "wait for a session file for $CAM_COLD"
    if [ $CHECK = 0 ]; then
      printf '  waiting for lake-provisioner'; for _ in $(seq 1 45); do [ -f "$OVERLAY/lake/$CAM_COLD.json" ] && break; printf .; sleep 2; done; echo
      if [ -f "$OVERLAY/lake/$CAM_COLD.json" ]; then envset CAM_COLD_PATH lake; done_ "session file written; the cool decoder will use lake.html (Agora, H.265)"
      else
        fail "no session for $CAM_COLD after 90 s"
        fix "cd $ROOT && docker compose logs --tail 20 lake-provisioner   ('no lake cameras' = Wyze does not mark this camera as lake; set CAM_COLD_PATH=kvs in .env)"
      fi
    fi
  else
    info "$CAM_COLD is a $MODEL, which the bridge reaches over Kinesis WebRTC like the hot side; no Agora session needed."
    [ $CHECK = 1 ] || envset CAM_COLD_PATH kvs; done_ "CAM_COLD_PATH=kvs (the cool decoder will use cam.html)"
  fi
fi

# =========================================================================================================
step "6. Agora Web SDK (served locally by the bridge for the lake player)"
if [ -s "$OVERLAY/agora-rtc-sdk.js" ]; then done_ "overlay/agora-rtc-sdk.js present ($(du -h "$OVERLAY/agora-rtc-sdk.js" | cut -f1))"
else
  todo "download agora-rtc-sdk.js (players/get-agora-sdk.sh)"
  if [ $CHECK = 0 ]; then
    ( cd "$KIT/players" && bash get-agora-sdk.sh >/dev/null ) && cp "$KIT/players/agora-rtc-sdk.js" "$OVERLAY/" || die "download failed" "cd $KIT/players && ./get-agora-sdk.sh && cp agora-rtc-sdk.js $OVERLAY/"
    done_ "SDK downloaded"
  fi
fi

# =========================================================================================================
step "7. OBS: profile, scene, obs-websocket, and the stream key (YOU)"
haskey() { $PY -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['settings'].get('key') else 1)" "$OBSDIR/basic/profiles/SnakeCam/service.json" 2>/dev/null; }
if [ -f "$OBSDIR/basic/scenes/SnakeCam.json" ] && [ -f "$OBSDIR/basic/profiles/SnakeCam/basic.ini" ]; then done_ "OBS SnakeCam scene + profile installed"
else
  todo "install the SnakeCam scene and profile into OBS"
  if [ $CHECK = 0 ]; then
    pgrep -xq OBS && die "OBS is running; it would overwrite the config on quit" "quit OBS (or: launchctl unload ~/Library/LaunchAgents/com.snakecam.obs.plist), then ./install.sh"
    bash "$KIT/obs/install-obs-config.sh" --root "$ROOT" >/dev/null || die "OBS config install failed" "$KIT/obs/install-obs-config.sh --root $ROOT"
    done_ "scene + profile installed"
  fi
fi
if [ -f "$OBSDIR/plugin_config/obs-websocket/config.json" ] && grep -q '"server_enabled": *true' "$OBSDIR/plugin_config/obs-websocket/config.json"; then done_ "obs-websocket enabled on :4455"
else todo "obs-websocket (OBS > Tools > WebSocket Server Settings > Enable, port 4455, no auth)"; fi
if haskey; then done_ "Twitch stream key is in the OBS profile"
else
  todo "YOU: paste your Twitch stream key into OBS"
  info "Twitch Creator Dashboard > Settings > Stream > Primary Stream Key  ->  OBS > Settings > Stream > Stream Key, then QUIT OBS so it saves."
  if [ $CHECK = 0 ] && [ $YES = 0 ]; then
    open -a OBS 2>/dev/null || true
    while ! haskey; do pause "Paste the key in OBS, quit OBS" || break; done
    haskey && done_ "stream key saved" || warn "no stream key yet; the OBS agent is not loaded until there is one"
  fi
fi

# =========================================================================================================
step "8. Twitch chat bot: developer app (YOU) + device-code login (YOU)"
CID="$(envget TWITCH_CLIENT_ID)"; CHAN="$(envget TWITCH_CHANNEL)"
if [ -n "$CID" ] && [ -n "$CHAN" ]; then done_ "TWITCH_CLIENT_ID + TWITCH_CHANNEL=$CHAN"
else
  todo "TWITCH_CLIENT_ID / TWITCH_CHANNEL in .env"
  info "YOU: https://dev.twitch.tv/console/apps > Register Your Application: name anything, OAuth redirect http://localhost:3000,"
  info "     category Chat Bot, client type PUBLIC. Copy the Client ID (no secret needed)."
  if [ $CHECK = 0 ] && [ $YES = 0 ]; then
    ask CID "Twitch app Client ID" "$CID"; ask CHAN "your Twitch channel name (the account that streams)" "$CHAN"
    [ -n "$CID" ] && [ -n "$CHAN" ] && { envset TWITCH_CLIENT_ID "$CID"; envset TWITCH_CHANNEL "$CHAN"; done_ "saved"; } || warn "left empty; the bot and watchdog stay off"
  fi
fi
if [ -f "$CHATBOT/token.json" ]; then done_ "bot token chatbot/token.json ($(envget TWITCH_BOT_NICK))"
elif [ -z "$CID" ]; then todo "bot login (needs the client id first)"
else
  todo "bot login: chatbot/auth.py prints a link + code; approve it signed in as the BOT account"
  if [ $CHECK = 0 ] && [ $YES = 0 ]; then
    info "The bot can be your channel account (simplest) or a separate account (make it a moderator: /mod name)."
    "$VENV/bin/python" "$CHATBOT/auth.py" || warn "login not completed; re-run:  $VENV/bin/python $CHATBOT/auth.py"
    [ -f "$CHATBOT/token.json" ] && done_ "token saved"
  fi
fi

# =========================================================================================================
step "9. Govee Bluetooth thermometers (H5075 class), one per side"
if [ -x "$HOME/Applications/SnakeSensors.app/Contents/MacOS/SnakeSensors" ]; then done_ "SnakeSensors.app built in ~/Applications (signed bundle with Bluetooth permission)"
else
  todo "build sensors/SnakeSensors.app (sensors/build.sh)"
  [ $CHECK = 1 ] || { bash "$ROOT/sensors/build.sh" >/dev/null || die "sensor app build failed" "$ROOT/sensors/build.sh"; done_ "built"; }
fi
if [ -n "$(envget SENSOR_HOT)" ] && [ -n "$(envget SENSOR_COOL)" ]; then done_ "SENSOR_HOT=$(envget SENSOR_HOT)  SENSOR_COOL=$(envget SENSOR_COOL)"
else
  todo "scan for Govee beacons and write SENSOR_HOT / SENSOR_COOL"
  if [ $CHECK = 0 ] && [ $YES = 0 ]; then
    info "Scanning 15 s (macOS asks for Bluetooth permission the first time; allow it). Hold the hot-side sensor in your hand to tell them apart."
    SCAN="$($PY "$ROOT/sensors/govee_scan.py" 2>&1)"; echo "$SCAN" | sed 's/^/    /'
    NAMES="$(echo "$SCAN" | awk '/°C/{print $1}')"
    if [ -n "$NAMES" ]; then
      ask SH "beacon name for the HOT side" "$(echo "$NAMES" | sed -n 1p)"; ask SC "beacon name for the COOL side" "$(echo "$NAMES" | sed -n 2p)"
      [ -n "$SH" ] && envset SENSOR_HOT "$SH"; [ -n "$SC" ] && envset SENSOR_COOL "$SC"; done_ "saved"
    else warn "no beacons heard; put the sensors within a few metres and re-run, or set SENSOR_HOT/SENSOR_COOL in .env by hand (names look like GVH5075_XXXX)"; fi
    ask TU "temperature unit shown on the overlay (F or C)" "$(envget TEMP_UNIT)"; [ -n "$TU" ] && envset TEMP_UNIT "$TU"
  fi
fi

# =========================================================================================================
step "10. Location (weather, sunrise/sunset for the overlay and the bot)"
LAT="$(envget CLEOBOT_LAT)"; LON="$(envget CLEOBOT_LON)"
PLACEHOLDER=0; for f in overlay.html ambience.html; do grep -q "LATITUDE" "$OVERLAY/$f" 2>/dev/null && PLACEHOLDER=1; done
if [ -n "$LAT" ] && [ -n "$LON" ] && [ $PLACEHOLDER = 0 ]; then done_ "lat/lon $LAT, $LON (in .env and in overlay/overlay.html + ambience.html)"
else
  todo "set CLEOBOT_LAT/CLEOBOT_LON and replace LATITUDE/LONGITUDE in the overlay copies"
  if [ $CHECK = 0 ]; then
    info "City-level is plenty (Open-Meteo, free, no key). Los Angeles is 34.05, -118.24."
    ask LAT "latitude" "${LAT:-34.05}"; ask LON "longitude" "${LON:--118.24}"
    envset CLEOBOT_LAT "$LAT"; envset CLEOBOT_LON "$LON"
    for f in overlay.html ambience.html; do [ -f "$OVERLAY/$f" ] && sed -i '' -e "s/lat: LATITUDE/lat: $LAT/" -e "s/lon: LONGITUDE/lon: $LON/" "$OVERLAY/$f"; done
    done_ "location written"
  fi
fi

# =========================================================================================================
step "11. Claude backend for the bot (cli = your subscription via the claude command, api = API key)"
BACKEND="$(envget CLEOBOT_LLM_BACKEND)"
claude_ok() { has claude && claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }
case "$BACKEND" in
  cli) if claude_ok; then done_ "backend cli: claude $(claude --version 2>/dev/null | head -1) is signed in"
       elif has claude; then todo "sign in the claude command"; info "YOU: run  claude  in a Terminal, choose 'Claude account', approve the code in the browser, then /exit."
            [ $CHECK = 1 ] || [ $YES = 1 ] || { pause "Sign in to claude" && claude_ok && done_ "signed in" || warn "still not signed in; the bot will fall back to templates"; }
       else todo "install the claude command"; [ $CHECK = 1 ] || { brew install --cask claude-code 2>/dev/null || npm install -g @anthropic-ai/claude-code || warn "install failed: brew install --cask claude-code"; }; fi
       [ "$(envget CLEOBOT_CLI_BIN)" = "$(command -v claude)" ] || [ ! "$(command -v claude)" ] || envset CLEOBOT_CLI_BIN "$(command -v claude)" ;;
  api) if [ -n "$(envget ANTHROPIC_API_KEY)" ]; then done_ "backend api: ANTHROPIC_API_KEY set"
       else todo "store an API key (chatbot/set-claude-key.sh)"; [ $CHECK = 1 ] || [ $YES = 1 ] || bash "$CHATBOT/set-claude-key.sh"; fi ;;
  off) done_ "backend off (kill switch): the bot answers from templates only" ;;
  *)   todo "choose a backend"
       if [ $CHECK = 0 ]; then
         ask BACKEND "backend: cli (claude command, subscription) / api (API key) / off" "$(has claude && echo cli || echo off)"
         envset CLEOBOT_LLM_BACKEND "$BACKEND"; info "re-run ./install.sh to finish setting up '$BACKEND'"
       fi ;;
esac

# =========================================================================================================
step "12. launchd agents (everything starts at login and restarts on crash)"
ALL="relay hotcam coolcam sensors obs chatbot watchdog"
MISSINGP=""; for a in $ALL; do [ -f "$AGENTS/com.snakecam.$a.plist" ] || MISSINGP="$MISSINGP $a"; done
STALE=0; for a in relay chatbot watchdog; do f="$AGENTS/com.snakecam.$a.plist"; [ -f "$f" ] && ! grep -q "$ROOT/" "$f" && STALE=1; done
if [ -z "$MISSINGP" ] && [ $STALE = 0 ] && ! grep -q "YOUR-HOT-CAM\|YOUR-COOL-CAM" "$AGENTS"/com.snakecam.*cam.plist 2>/dev/null; then done_ "7 plists installed in ~/Library/LaunchAgents"
else
  todo "install plists (scripts/install-launchd.sh):${MISSINGP:- refresh}"
  [ $CHECK = 1 ] || { bash "$KIT/scripts/install-launchd.sh" --root "$ROOT" >/dev/null || die "plist install failed" "$KIT/scripts/install-launchd.sh --root $ROOT"; done_ "plists installed"; }
fi
want() { case $1 in
  sensors) [ -n "$(envget SENSOR_HOT)" ] && [ -x "$HOME/Applications/SnakeSensors.app/Contents/MacOS/SnakeSensors" ] ;;
  obs) haskey ;;
  chatbot|watchdog) [ -f "$CHATBOT/token.json" ] && [ -n "$(envget TWITCH_CHANNEL)" ] ;;
  *) true ;; esac; }
for a in $ALL; do
  if loaded com.snakecam.$a; then done_ "com.snakecam.$a loaded"
  elif want $a; then todo "load com.snakecam.$a"; [ $CHECK = 1 ] || { launchctl load "$AGENTS/com.snakecam.$a.plist" 2>/dev/null && done_ "loaded $a" || fail "could not load $a: launchctl load $AGENTS/com.snakecam.$a.plist"; }
  else info "com.snakecam.$a not loaded yet (finish the step above it, then re-run)"; fi
done

# =========================================================================================================
step "13. Unattended Mac: auto-login and never sleep (YOU, System Settings)"
AUTOL="$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
if [ "$AUTOL" = "$(id -un)" ]; then done_ "auto-login as $AUTOL"
else todo "System Settings > Users & Groups > 'Automatically log in as' = $(id -un)  (launchd LaunchAgents only run inside a logged-in session)"; fi
if pmset -g 2>/dev/null | grep -qE "^\s*sleep\s+0"; then done_ "system sleep is off"
else todo "System Settings > Energy > Prevent automatic sleeping = on   (or: sudo pmset -a sleep 0 disksleep 0)"; fi
pmset -g 2>/dev/null | grep -qE "^\s*autorestart\s+1" && done_ "restart after power failure is on" || todo "System Settings > Energy > Start up automatically after a power failure   (or: sudo pmset -a autorestart 1)"
info "FileVault must be OFF for auto-login to work after a reboot."

# =========================================================================================================
printf '\n%s%s==> Summary%s  done: %s   todo: %s   failed: %s\n' "$B" "$C" "$N" "$NDONE" "$NTODO" "$NFAIL"
if [ $CHECK = 1 ]; then
  [ $NTODO = 0 ] && [ $NFAIL = 0 ] && printf '%sEverything is already done.%s\n' "$G" "$N" || printf 'Run ./install.sh (without --check) to do the [todo] items.\n'
  exit $NFAIL
fi
[ $NTODO = 0 ] && [ $NFAIL = 0 ] && printf '%sInstall complete.%s Give the cameras a minute, then check your Twitch page.\n' "$G" "$N"
step "14. Doctor"
bash "$KIT/doctor.sh" --root "$ROOT"
