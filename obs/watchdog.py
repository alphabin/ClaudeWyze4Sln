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
CAMS = {"hot": ("Hot Side (Relay)", "hotcam"), "cool": ("Cool Side (Relay)", "coolcam"), "hothide": ("Hot Hide (OG)", "hothide"), "coldhide": ("Cold Hide (OG)", "coldhide")}
LABELS = {"hot": "Hot side", "cool": "Cool side", "hothide": "Hot hide", "coldhide": "Cold hide", "reel": "Highlight reel · her on the move", "soon": "Hot side · camera returning"}
_dead = {k: 3 for k in CAMS}; _layout = {"key": None}          # every camera starts "dead" until a probe succeeds: no black cell at startup
def cam_alive(path):
    try: return subprocess.run([FFPROBE, "-v", "error", "-rtsp_transport", "tcp", "-select_streams", "v", "-show_entries", "stream=width", "-of", "csv=p=0", f"rtsp://127.0.0.1:8555/{path}"], capture_output=True, timeout=12).returncode == 0
    except Exception: return False
def she_settled():
    """No cool-side motion for 10 min (the sensor hub) = nothing going on: the reel may play."""
    try:
        m = json.load(urllib.request.urlopen("http://127.0.0.1:5090/state.json", timeout=4)).get("motion", {}).get("cool", {})
        return not m.get("moving") and time.time() - m.get("lastMove", 0) > 600
    except Exception: return True
def plan(alive, settled):
    """Which source goes in which cell. Stage = 1920x540 at y=270. Hero (960x540) left; 2x2 grid (480x270) right.
    Both pan cams alive: the classic split, hides underneath the... no — hides always get the grid; the hero is the cool V4 (or the hot side when the V4 is gone)."""
    cells = []
    hero = "cool" if alive["cool"] else "hot" if alive["hot"] else None
    if hero: cells.append((hero, 0, 270, 960, 540))
    grid = [(960, 270), (1440, 270), (960, 540), (1440, 540)]; slots = []
    for k in ("hot", "cool"):
        if k != hero and alive[k]: slots.append(k)
    for k in ("hothide", "coldhide"):
        if alive[k]: slots.append(k)
    if not alive["hot"]: slots.append("reel" if settled and os.path.exists(f"{ROOT}/overlay/reel.mp4") else "moving")
    if not alive["hot"] and len(slots) < 4: slots.append("soon")
    for k, (x, y) in zip(slots[:4], grid): cells.append((k, x, y, 480, 270))
    return cells
def apply_layout(cells, alive):
    scene = obs([("GetCurrentProgramScene", None)])[0]["currentProgramSceneName"]; items = {i["sourceName"]: i["sceneItemId"] for i in obs([("GetSceneItemList", {"sceneName": scene})])[0]["sceneItems"]}
    placed = {k: (x, y, w, h) for k, x, y, w, h in cells}; reqs = []
    for key, src in list(((k, v[0]) for k, v in CAMS.items())) + [("reel", "Highlights")]:
        iid = items.get(src)
        if not iid: continue
        if key in placed:
            x, y, w, h = placed[key]
            reqs += [("SetSceneItemIndex", {"sceneName": scene, "sceneItemId": iid, "sceneItemIndex": 0}), ("SetSceneItemEnabled", {"sceneName": scene, "sceneItemId": iid, "sceneItemEnabled": True}),
                     ("SetSceneItemTransform", {"sceneName": scene, "sceneItemId": iid, "sceneItemTransform": {"positionX": x, "positionY": y, "boundsType": "OBS_BOUNDS_SCALE_INNER", "boundsWidth": w, "boundsHeight": h, "boundsAlignment": 0, "cropTop": 0, "cropBottom": 0, "cropLeft": 0, "cropRight": 0}})]
        else: reqs.append(("SetSceneItemEnabled", {"sceneName": scene, "sceneItemId": iid, "sceneItemEnabled": False}))
    obs(reqs)
    json.dump({"cells": [{"key": k, "label": LABELS.get(k, k), "x": x, "y": y, "w": w, "h": h, "live": k in CAMS} for k, x, y, w, h in cells], "dead": [k for k in CAMS if not alive[k]], "ts": int(time.time())}, open(f"{ROOT}/overlay/layout.json", "w"))
    json.dump({"dead": "hot" if not alive["hot"] else None, "reel": any(k == "reel" for k, *_ in cells), "ts": int(time.time())}, open(f"{ROOT}/overlay/cams.json", "w"))   # kept for the bot + old overlay code
_reel = {"building": False}
def reel_refresh():
    """Rebuild overlay/reel.mp4 from her newest movement clips (scripts/build-reel.py) every 2 h while a camera is dead, then make OBS reopen it."""
    f = f"{ROOT}/overlay/reel.mp4"
    if _reel["building"] or (os.path.exists(f) and time.time() - os.path.getmtime(f) < 7200): return
    _reel["building"] = True
    def run():
        try:
            r = subprocess.run([sys.executable, f"{ROOT}/scripts/build-reel.py", "12"], capture_output=True, text=True, timeout=2400); log("reel:", (r.stdout or r.stderr).strip()[-80:])
            obs([("SetInputSettings", {"inputName": "Highlights", "inputSettings": {"local_file": f + ".none"}}), ("SetInputSettings", {"inputName": "Highlights", "inputSettings": {"local_file": f}})])   # reopen the new file
        except Exception as e: log("reel error:", e)
        finally: _reel["building"] = False
    import threading; threading.Thread(target=run, daemon=True).start()
def solo_tick():
    for key, (_, path) in CAMS.items(): _dead[key] = 0 if cam_alive(path) else _dead[key] + 1
    alive = {k: _dead[k] < 3 for k in CAMS}
    if not alive["hot"]: reel_refresh()
    cells = plan(alive, she_settled()); key = json.dumps(cells)
    if key != _layout["key"]:
        apply_layout(cells, alive); _layout["key"] = key; log("layout: " + ", ".join(f"{k}@{x},{y}" for k, x, y, *_ in cells) + " | dead: " + ",".join(k for k in CAMS if not alive[k]))
strikes = 0; log(f"watchdog for #{CHANNEL}, restart after {STRIKES} offline minutes")
while True:
    try: solo_tick()
    except Exception as e: log("layout check error:", e)
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
