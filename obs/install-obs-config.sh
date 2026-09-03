#!/bin/bash
# Installs the SnakeCam profile + scene into OBS. Run once, after OBS is installed
# and after CAM_HOT / CAM_COLD are set in .env. Safe to re-run.
set -eu
KIT="$(cd "$(dirname "$0")/.." && pwd)"
HERE="${SNAKECAM_ROOT:-$KIT}"          # runtime root: where .env and overlay/ live
[ "${1:-}" = "--root" ] && HERE="$(cd "$2" && pwd)"
set -a; . "$HERE/.env"; set +a
OBS="$HOME/Library/Application Support/obs-studio"
mkdir -p "$OBS/basic/scenes" "$OBS/basic/profiles/SnakeCam"

sed -e "s#CAM_HOT#${CAM_HOT}#" -e "s#CAM_COLD#${CAM_COLD}#" \
    -e "s#CAM_HOT#${CAM_HOT}#g" -e "s#CAM_COLD#${CAM_COLD}#g" -e "s#OVERLAY_PATH#${HERE}/overlay/overlay.html#" \
    "$KIT/obs/SnakeCam.json" > "$OBS/basic/scenes/SnakeCam.json"
cp "$KIT/obs/basic.ini"    "$OBS/basic/profiles/SnakeCam/basic.ini"
# never clobber a stream key the user already pasted into OBS
[ -f "$OBS/basic/profiles/SnakeCam/service.json" ] || cp "$KIT/obs/service.json" "$OBS/basic/profiles/SnakeCam/"

# obs-websocket on :4455 WITH a password: obs-websocket listens on every interface, so without one anybody on the
# Wi-Fi could stop the stream, swap the stream key or add sources. The password lives in .env as OBS_WS_PASSWORD;
# doctor.sh, the watchdog and obsstat.py read it from there. Only written when OBS has never configured it.
WSCFG="$OBS/plugin_config/obs-websocket/config.json"
if [ ! -f "$WSCFG" ]; then
  PW="$(grep -E '^OBS_WS_PASSWORD=' "$HERE/.env" | head -1 | cut -d= -f2- | tr -d '"')"
  if [ -z "$PW" ]; then PW="$(openssl rand -hex 16)"; printf '\nOBS_WS_PASSWORD=%s\n' "$PW" >> "$HERE/.env"; chmod 600 "$HERE/.env"; fi
  mkdir -p "$(dirname "$WSCFG")"
  printf '{"alerts_enabled":false,"auth_required":true,"first_load":false,"server_enabled":true,"server_password":"%s","server_port":4455}\n' "$PW" > "$WSCFG"
fi

# make it the active profile/collection (OBS 31 uses user.ini, older uses global.ini)
for cfg in user.ini global.ini; do
  f="$OBS/$cfg"; touch "$f"
  python3 - "$f" <<'PY'
import sys,configparser
p=sys.argv[1]; c=configparser.ConfigParser(); c.optionxform=str; c.read(p)
if 'Basic' not in c: c['Basic']={}
c['Basic'].update({'Profile':'SnakeCam','ProfileDir':'SnakeCam','SceneCollection':'SnakeCam','SceneCollectionFile':'SnakeCam'})
c.write(open(p,'w'),space_around_delimiters=False)
PY
done
if python3 -c "import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))['settings'].get('key') else 1)" "$OBS/basic/profiles/SnakeCam/service.json" 2>/dev/null; then
  echo "OBS config installed (stream key already present)."
else
  echo "OBS config installed. Open OBS, paste your Twitch key: Settings > Stream > Stream Key, then quit OBS."
fi
