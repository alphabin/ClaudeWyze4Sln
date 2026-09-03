#!/bin/bash
# Installs the launchd services with this kit's location and your camera names filled in.
# Re-run after moving the folder or changing CAM_HOT / CAM_COLD in .env. Does not load anything.
#   relay     - mediamtx (WHIP in :8890, RTSP out :8555)
#   hotcam    - headless Chrome decoding the hot cam (Kinesis WebRTC) into the relay
#   coolcam   - headless Chrome decoding the cool cam (Agora H.265 "lake", or Kinesis if CAM_COLD_PATH=kvs)
#   sensors   - Govee Bluetooth reader + hub (:5090); needs sensors/build.sh first
#   obs       - OBS starting the stream at login, tray-only
#   chatbot   - the chat bot;  watchdog - restarts the stream output if Twitch drops the ingest
# Placeholders in launchd/*.plist: __PROJECT__ (the runtime root) and __HOME__.
#   ROOT is the folder holding .env / overlay / chatbot (default: the kit itself, or --root DIR / $SNAKECAM_ROOT).
set -eu
KIT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${SNAKECAM_ROOT:-$KIT}"
[ "${1:-}" = "--root" ] && ROOT="$(cd "$2" && pwd)"
ENV="$ROOT/.env"
getenv() { grep -E "^$1=" "$ENV" 2>/dev/null | head -1 | cut -d= -f2- | sed -e 's/[[:space:]]*#.*$//' -e 's/^"//' -e 's/"$//'; }
CAM_HOT="$(getenv CAM_HOT)"; CAM_COLD="$(getenv CAM_COLD)"; COLD_PATH="$(getenv CAM_COLD_PATH)"
MEDIAMTX="$(command -v mediamtx || echo /opt/homebrew/bin/mediamtx)"
[ -n "$CAM_HOT" ]  || echo "warning: CAM_HOT is empty in $ENV - the hotcam agent will keep YOUR-HOT-CAM"
[ -n "$CAM_COLD" ] || echo "warning: CAM_COLD is empty in $ENV - the coolcam agent will keep YOUR-COOL-CAM"
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
for f in "$KIT"/launchd/*.plist; do
  name=$(basename "$f")
  sed -e "s|__PROJECT__|$ROOT|g" -e "s|__HOME__|$HOME|g" \
      -e "s|/opt/homebrew/bin/mediamtx|$MEDIAMTX|g" \
      -e "s|cam=YOUR-HOT-CAM|cam=${CAM_HOT:-YOUR-HOT-CAM}|g" \
      -e "s|cam=YOUR-COOL-CAM|cam=${CAM_COLD:-YOUR-COOL-CAM}|g" "$f" > ~/Library/LaunchAgents/"$name"
  if [ "$name" = com.snakecam.coolcam.plist ] && [ "${COLD_PATH:-lake}" = kvs ]; then
    # the cool camera is not an Agora ("lake") camera: decode it with the Kinesis player instead
    sed -i '' -e "s|lake.html?cam=\([^&]*\)&amp;res=[^&]*&amp;codec=[^&]*&amp;|cam.html?cam=\1\&amp;|" ~/Library/LaunchAgents/"$name"
  fi
  plutil -lint ~/Library/LaunchAgents/"$name" >/dev/null && echo "installed $name"
done
echo
echo "Load what you need, e.g.:"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.relay.plist"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.hotcam.plist ~/Library/LaunchAgents/com.snakecam.coolcam.plist"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.obs.plist"
echo "(install.sh does this for you; 'scripts/Start Snakecam.command' loads everything.)"
