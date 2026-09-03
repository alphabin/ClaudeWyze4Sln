#!/bin/bash
# Installs the launchd services with this kit's location filled in. Re-run after moving the folder.
#   relay    - mediamtx (WHIP in :8890, RTSP out :8555)
#   coolcam  - headless Chrome decoding an H.265 "lake" camera into the relay  (edit the camera name in the plist first)
#   obs      - OBS starting the stream at login, tray-only
#   sensors  - optional Govee Bluetooth reader + hub (:5090); needs sensors/build.sh first
set -eu
KIT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
for f in "$KIT"/launchd/*.plist; do
  name=$(basename "$f")
  sed -e "s|__PROJECT__|$KIT|g" -e "s|__HOME__|$HOME|g" "$f" > ~/Library/LaunchAgents/"$name"
  plutil -lint ~/Library/LaunchAgents/"$name" >/dev/null && echo "installed $name"
done
echo
echo "Load what you need, e.g.:"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.relay.plist"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.coolcam.plist"
echo "  launchctl load ~/Library/LaunchAgents/com.snakecam.obs.plist"
