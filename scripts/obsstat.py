# usage: python3 obsstat.py [seconds] [screenshot.png]  -> frame-drop % over the window (and optional program screenshot)
import json,websocket,time,sys,base64
secs=int(sys.argv[1]) if len(sys.argv)>1 else 10; shot=sys.argv[2] if len(sys.argv)>2 else None
for _ in range(60):
    try: ws=websocket.create_connection("ws://127.0.0.1:4455",timeout=15); break
    except OSError: time.sleep(5)
ws.recv(); ws.send(json.dumps({"op":1,"d":{"rpcVersion":1}})); ws.recv(); n=[0]
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
