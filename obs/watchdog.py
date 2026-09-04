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
def obs_auth(ws, password):
    """obs-websocket v5 handshake: answer the Hello challenge with the password (from OBS_WS_PASSWORD in .env)."""
    import base64, hashlib
    hello = json.loads(ws.recv()); auth = (hello.get("d") or {}).get("authentication"); ident = {"rpcVersion": 1}
    if auth:
        secret = base64.b64encode(hashlib.sha256((password + auth["salt"]).encode()).digest()).decode()
        ident["authentication"] = base64.b64encode(hashlib.sha256((secret + auth["challenge"]).encode()).digest()).decode()
    ws.send(json.dumps({"op": 1, "d": ident}))
    if json.loads(ws.recv()).get("op") != 2: raise RuntimeError("obs-websocket rejected the password (OBS_WS_PASSWORD in .env)")
def obs(requests):
    ws = websocket.create_connection("ws://127.0.0.1:4455", timeout=10); obs_auth(ws, ENV.get("OBS_WS_PASSWORD", "")); out = []
    for i, (t, d) in enumerate(requests):
        ws.send(json.dumps({"op": 6, "d": {"requestType": t, "requestId": str(i), "requestData": d or {}}}))
        while True:
            m = json.loads(ws.recv())
            if m["op"] == 7 and m["d"]["requestId"] == str(i): out.append(m["d"].get("responseData")); break
    ws.close(); return out
# ---- solo camera: a dead relay (she constricted the hot cam, 2026-09-04) must not leave a black half on the stream
import subprocess
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); FFPROBE = ENV.get("CLEOBOT_FFMPEG", "/opt/homebrew/bin/ffmpeg").replace("ffmpeg", "ffprobe")
CAMS = {"hot": ("Hot Side (Relay)", "hotcam", 0), "cool": ("Cool Side (Relay)", "coolcam", 960)}
_dead = {"hot": 0, "cool": 0}; _solo = {"mode": None}
def cam_alive(path):
    try: return subprocess.run([FFPROBE, "-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v", "-show_entries", "stream=width", "-of", "csv=p=0", f"rtsp://127.0.0.1:8555/{path}"], capture_output=True, timeout=12).returncode == 0
    except Exception: return False
def solo_layout(dead):
    """dead: 'hot' | 'cool' | None. The living camera fills the 1920x540 stage (its own middle band, cropped), the dead one is hidden; overlay/cams.json tells the overlay."""
    scene = obs([("GetCurrentProgramScene", None)])[0]["currentProgramSceneName"]; items = {i["sourceName"]: i["sceneItemId"] for i in obs([("GetSceneItemList", {"sceneName": scene})])[0]["sceneItems"]}
    reqs = []
    for key, (src, _, x) in CAMS.items():
        iid = items.get(src)
        if not iid: continue
        if dead == key: reqs.append(("SetSceneItemEnabled", {"sceneName": scene, "sceneItemId": iid, "sceneItemEnabled": False}))
        else:
            reqs += [("SetSceneItemEnabled", {"sceneName": scene, "sceneItemId": iid, "sceneItemEnabled": True}),
                     ("SetSceneItemTransform", {"sceneName": scene, "sceneItemId": iid, "sceneItemTransform": {"positionX": x, "positionY": 270, "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsWidth": 960, "boundsHeight": 540, "boundsAlignment": 0, "cropTop": 0, "cropBottom": 0, "cropLeft": 0, "cropRight": 0}})]
    reel = items.get("Highlights")                                                     # the dead camera's slot plays her highlight reel (overlay/reel.mp4)
    if reel:
        x = CAMS[dead][2] if dead else 0
        reqs += [("SetSceneItemEnabled", {"sceneName": scene, "sceneItemId": reel, "sceneItemEnabled": bool(dead)}),
                 ("SetSceneItemTransform", {"sceneName": scene, "sceneItemId": reel, "sceneItemTransform": {"positionX": x, "positionY": 270, "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsWidth": 960, "boundsHeight": 540, "boundsAlignment": 0}})]
    obs(reqs); json.dump({"dead": dead, "reel": bool(reel and dead and os.path.exists(f"{ROOT}/overlay/reel.mp4")), "ts": int(time.time())}, open(f"{ROOT}/overlay/cams.json", "w"))
_reel = {"building": False}
def reel_refresh():
    """Rebuild overlay/reel.mp4 from her newest movement clips (scripts/build-reel.py) every 2 h while a camera is dead, then make OBS reopen it."""
    f = f"{ROOT}/overlay/reel.mp4"
    if _reel["building"] or (os.path.exists(f) and time.time() - os.path.getmtime(f) < 7200): return
    _reel["building"] = True
    def run():
        try:
            r = subprocess.run([sys.executable, f"{ROOT}/scripts/build-reel.py", "12"], capture_output=True, text=True, timeout=1200); log("reel:", (r.stdout or r.stderr).strip()[-80:])
            obs([("SetInputSettings", {"inputName": "Highlights", "inputSettings": {"local_file": f + ".none"}}), ("SetInputSettings", {"inputName": "Highlights", "inputSettings": {"local_file": f}})])   # reopen the new file
        except Exception as e: log("reel error:", e)
        finally: _reel["building"] = False
    import threading; threading.Thread(target=run, daemon=True).start()
def solo_tick():
    for key, (_, path, _) in CAMS.items(): _dead[key] = 0 if cam_alive(path) else _dead[key] + 1
    dead = next((k for k in ("hot", "cool") if _dead[k] >= 3), None)
    if dead == "hot" and _dead["cool"] >= 3: dead = None                                   # both gone: leave the layout alone
    if dead: reel_refresh()
    if dead != _solo["mode"]:
        solo_layout(dead); _solo["mode"] = dead; log(f"cameras: {dead + ' camera dead, ' + ('cool' if dead == 'hot' else 'hot') + ' side goes solo' if dead else 'both back, split view restored'}")
strikes = 0; log(f"watchdog for #{CHANNEL}, restart after {STRIKES} offline minutes")
while True:
    try: solo_tick()
    except Exception as e: log("solo check error:", e)
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
