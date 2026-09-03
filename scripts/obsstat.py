# usage: python3 obsstat.py [seconds] [screenshot.png]  -> frame-drop % over the window (and optional program screenshot)
import json,websocket,time,sys,base64,os
def _env():
    d={}
    try:
        for l in open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"..",".env")):
            l=l.split("#",1)[0].strip()
            if "=" in l: k,v=l.split("=",1); d[k.strip()]=v.strip().strip('"')
    except FileNotFoundError: pass
    return d
def obs_auth(ws, password):
    """obs-websocket v5 handshake: answer the Hello challenge with the password (from OBS_WS_PASSWORD in .env)."""
    import base64, hashlib
    hello = json.loads(ws.recv()); auth = (hello.get("d") or {}).get("authentication"); ident = {"rpcVersion": 1}
    if auth:
        secret = base64.b64encode(hashlib.sha256((password + auth["salt"]).encode()).digest()).decode()
        ident["authentication"] = base64.b64encode(hashlib.sha256((secret + auth["challenge"]).encode()).digest()).decode()
    ws.send(json.dumps({"op": 1, "d": ident}))
    if json.loads(ws.recv()).get("op") != 2: raise RuntimeError("obs-websocket rejected the password (OBS_WS_PASSWORD in .env)")
secs=int(sys.argv[1]) if len(sys.argv)>1 else 10; shot=sys.argv[2] if len(sys.argv)>2 else None
for _ in range(60):
    try: ws=websocket.create_connection("ws://127.0.0.1:4455",timeout=15); break
    except OSError: time.sleep(5)
obs_auth(ws,_env().get("OBS_WS_PASSWORD","")); n=[0]
def req(t,data=None):
    n[0]+=1; rid=str(n[0]); ws.send(json.dumps({"op":6,"d":{"requestType":t,"requestId":rid,"requestData":data or {}}}))
    while True:
        m=json.loads(ws.recv())
        if m["op"]==7 and m["d"]["requestId"]==rid: return m["d"]
a=req("GetStats")["responseData"]; time.sleep(secs); b=req("GetStats")["responseData"]
dt=b["renderTotalFrames"]-a["renderTotalFrames"]; ds=b["renderSkippedFrames"]-a["renderSkippedFrames"]
print(f"{secs}s window: skipped {100*ds/max(1,dt):.1f}% of {dt} frames, fps {b['activeFps']:.1f}, cpu {b['cpuUsage']:.1f}%, streaming {req('GetStreamStatus')['responseData']['outputActive']}")
if shot:
    sc=req("GetCurrentProgramScene")["responseData"]["currentProgramSceneName"]
    open(shot,"wb").write(base64.b64decode(req("GetSourceScreenshot",{"sourceName":sc,"imageFormat":"png","imageWidth":1280})["responseData"]["imageData"].split(",",1)[1])); print("saved",shot)
