#!/bin/bash
# Double-click in Finder: takes the stream off air and stops everything. Start again with "Start Snakecam".
cd "$(dirname "$0")"
echo "■ OBS (stream ends)";  launchctl unload ~/Library/LaunchAgents/com.snakecam.obs.plist 2>/dev/null; sleep 3; pkill -x OBS 2>/dev/null; echo "   stopped"
echo "■ Camera decoders";  launchctl unload ~/Library/LaunchAgents/com.snakecam.hotcam.plist 2>/dev/null; launchctl unload ~/Library/LaunchAgents/com.snakecam.coolcam.plist 2>/dev/null; pkill -f "snakecam-hotcam|snakecam-coolcam" 2>/dev/null; echo "   stopped"
echo "■ Video relay";      launchctl unload ~/Library/LaunchAgents/com.snakecam.relay.plist 2>/dev/null; echo "   stopped"
echo "■ Chat bot";           launchctl unload ~/Library/LaunchAgents/com.snakecam.chatbot.plist 2>/dev/null; echo "   stopped"
echo "■ Sensors";            launchctl unload ~/Library/LaunchAgents/com.snakecam.sensors.plist 2>/dev/null; echo "   stopped"
echo "■ Wyze bridge + provisioner"; docker compose down 2>&1 | tail -1
echo; echo "Off air. (The Docker VM is left running; 'colima stop' if you want it fully down.)"
echo "This window can be closed."
