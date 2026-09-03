#!/bin/bash
# Downloads the Agora Web SDK the players need (the bridge serves it locally; OBS's browser can't reach Agora's CDN).
cd "$(dirname "$0")" && curl -sL -o agora-rtc-sdk.js "https://cdn.jsdelivr.net/npm/agora-rtc-sdk-ng@4.24.0/AgoraRTC_N-production.js" && ls -la agora-rtc-sdk.js
