#!/usr/bin/env python3
"""Stream watchdog: Twitch sometimes ends the ingest session (e.g. after a channel rename) while OBS keeps
sending into a dead connection and never reconnects. Every minute this asks Twitch whether the channel is
live; if OBS says it is streaming but Twitch says offline for STRIKES polls in a row, it restarts OBS's
stream output. Uses the chat bot's token (chatbot/token.json) and TWITCH_CLIENT_ID / TWITCH_CHANNEL from .env."""
import json, os, sys, time, urllib.request, urllib.parse
HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
import websocket   # from the chatbot venv
ENV = {}
for line in open(f"{ROOT}/.env"):
    if "=" in line and not line.startswith("#"): k, v = line.strip().split("=", 1); ENV[k] = v.split("#")[0].strip().strip('"')   # value only, no trailing comment
CHANNEL = ENV.get("TWITCH_CHANNEL", "").lower(); CLIENT_ID = ENV.get("TWITCH_CLIENT_ID", "")
STRIKES = int(os.environ.get("WATCHDOG_STRIKES", "3")); EVERY = 60
def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)
def token():
    try: return json.load(open(f"{ROOT}/chatbot/token.json")).get("access_token", "")
    except Exception: return ""
def twitch_live():
    """True / False, or None if the answer is unknown (network or auth problem) — never restart on unknown."""
    try:
        req = urllib.request.Request("https://api.twitch.tv/helix/streams?user_login=" + urllib.parse.quote(CHANNEL),
                                     headers={"Client-Id": CLIENT_ID, "Authorization": "Bearer " + token()})
        with urllib.request.urlopen(req, timeout=15) as r: return len(json.load(r).get("data", [])) > 0
    except Exception as e: log("twitch query failed:", e); return None
def obs(requests):
    ws = websocket.create_connection("ws://127.0.0.1:4455", timeout=10); ws.recv(); ws.send(json.dumps({"op": 1, "d": {"rpcVersion": 1}})); ws.recv(); out = []
    for i, (t, d) in enumerate(requests):
        ws.send(json.dumps({"op": 6, "d": {"requestType": t, "requestId": str(i), "requestData": d or {}}}))
        while True:
            m = json.loads(ws.recv())
            if m["op"] == 7 and m["d"]["requestId"] == str(i): out.append(m["d"].get("responseData")); break
    ws.close(); return out
strikes = 0; log(f"watchdog for #{CHANNEL}, restart after {STRIKES} offline minutes")
while True:
    try:
        st = obs([("GetStreamStatus", None)])[0]; active = st and st.get("outputActive")
        live = twitch_live() if active else None
        if active and live is False:
            strikes += 1; log(f"OBS streaming but Twitch says offline ({strikes}/{STRIKES})")
            if strikes >= STRIKES:
                obs([("StopStream", None)]); time.sleep(5); obs([("StartStream", None)]); log("stream output restarted"); strikes = 0; time.sleep(60)
        else:
            if strikes: log("back in sync"); strikes = 0
    except Exception as e: log("obs not reachable:", e); strikes = 0
    time.sleep(EVERY)
