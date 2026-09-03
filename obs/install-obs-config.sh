#!/bin/bash
# Installs the SnakeCam profile + scene into OBS. Run once, after OBS is installed
# and after CAM_HOT / CAM_COLD are set in .env. Safe to re-run.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
set -a; . "$HERE/.env"; set +a
OBS="$HOME/Library/Application Support/obs-studio"
mkdir -p "$OBS/basic/scenes" "$OBS/basic/profiles/SnakeCam"

sed -e "s#CAM_HOT#${CAM_HOT}#" -e "s#CAM_COLD#${CAM_COLD}#" \
    -e "s#CAM_HOT#${CAM_HOT}#g" -e "s#CAM_COLD#${CAM_COLD}#g" -e "s#OVERLAY_PATH#${HERE}/overlay/overlay.html#" \
    "$HERE/obs/SnakeCam.json" > "$OBS/basic/scenes/SnakeCam.json"
cp "$HERE/obs/basic.ini"    "$OBS/basic/profiles/SnakeCam/basic.ini"
# never clobber a stream key the user already pasted into OBS
[ -f "$OBS/basic/profiles/SnakeCam/service.json" ] || cp "$HERE/obs/service.json" "$OBS/basic/profiles/SnakeCam/"

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
echo "OBS config installed. Open OBS, paste your Twitch key: Settings > Stream."
