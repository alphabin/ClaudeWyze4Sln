#!/bin/bash
# Double-click in Finder: brings the whole snake stream up. Safe to run when it's already running.
cd "$(dirname "$0")"
echo "▶ Docker VM";        colima start 2>&1 | grep -E "done|error" | tail -1
echo "▶ Wyze bridge + Pan V4 provisioner"; docker compose up -d 2>&1 | tail -2
echo "▶ Video relay";      launchctl load ~/Library/LaunchAgents/com.snakecam.relay.plist 2>/dev/null; echo "   loaded"
echo "▶ Camera decoders";  launchctl load ~/Library/LaunchAgents/com.snakecam.hotcam.plist 2>/dev/null; launchctl load ~/Library/LaunchAgents/com.snakecam.coolcam.plist 2>/dev/null; echo "   loaded (two invisible headless Chromes)"
echo "▶ Sensors";          launchctl load ~/Library/LaunchAgents/com.snakecam.sensors.plist 2>/dev/null; echo "   loaded"
echo "▶ Chat bot";         if [ -f chatbot/token.json ] && grep -qE "^TWITCH_CHANNEL=.+" .env; then launchctl load ~/Library/LaunchAgents/com.snakecam.chatbot.plist 2>/dev/null; echo "   loaded"; else echo "   skipped (run chatbot/auth.py first)"; fi
echo "▶ OBS → Twitch";     launchctl load ~/Library/LaunchAgents/com.snakecam.obs.plist 2>/dev/null; echo "   loaded (OBS icon appears in the menu bar; click it to see the picture)"
echo; echo "Waiting 40s for the cameras…"; sleep 40
echo "▶ Provisioner:"; docker compose logs --no-log-prefix --tail 1 lake-provisioner
for c in hotcam coolcam; do printf "▶ Relay %-8s " $c; ffprobe -v error -rw_timeout 10000000 -rtsp_transport tcp -select_streams v -show_entries stream=codec_name,width,height -of csv=p=0 rtsp://127.0.0.1:8555/$c 2>&1 | tail -1; done
echo "▶ Sensors:";     tail -1 ~/Library/Logs/snakecam-sensors.log
echo "▶ OBS:";         f=$(ls -t "$HOME/Library/Application Support/obs-studio/logs"/*.txt | head -1); grep -E "Streaming Start|Connection to rtmp.*successful" "$f" | tail -1 || echo "   (no stream yet - give it another minute)"
echo; echo "Done. Check your Twitch page. This window can be closed."
