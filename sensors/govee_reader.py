#!/usr/bin/env python3
"""Listen for Govee H5075 Bluetooth beacons and publish the latest readings
to overlay/readings.js (for OBS) and logs/readings.json (for humans)."""
import asyncio, json, os, sys, time, signal, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from bleak import BleakScanner
from bleak.exc import BleakError

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
OUT_JS, OUT_JSON = f"{ROOT}/overlay/readings.js", f"{ROOT}/logs/readings.json"
GOVEE, STALE_S, WRITE_EVERY = 0xEC88, 120, 5

def env():
    d = {}
    try:
        for line in open(f"{ROOT}/.env"):
            line = line.split("#", 1)[0].strip()
            if "=" in line: k, v = line.split("=", 1); d[k.strip()] = v.strip()
    except FileNotFoundError: pass
    return d

def decode(mfr):
    raw = mfr.get(GOVEE)
    if not raw or len(raw) < 5: return None
    v = int.from_bytes(raw[1:4], "big"); neg = bool(v & 0x800000); v &= 0x7FFFFF
    c = v / 10000 * (-1 if neg else 1)
    return {"c": round(c, 1), "f": round(c * 9 / 5 + 32, 1), "rh": (v % 1000) / 10, "batt": raw[4]}

latest = {}
# ---- hub: tiny local HTTP API for the overlay and the camera players --------------
#   GET  /state.json   readings + motion + today's high/low + 24h samples (CORS: any local page)
#   POST /motion       {"cam": "hot"|"cool", "score": float}   from the player pages
HUB_PORT = 5090
motion = {}            # cam -> {"score": x, "ts": t, "lastMove": t}
MOVE_THRESHOLD = float(os.environ.get("MOVE_THRESHOLD", "24"))  # localized block difference (0-255) that counts as movement
MIN_BOUTS = int(os.environ.get("MIN_BOUTS", "12")); MIN_DAYS = int(os.environ.get("MIN_DAYS", "3"))   # evidence needed before the learned routine replaces the sunset default
MOVE_STREAK = int(os.environ.get("MOVE_STREAK", "8"))            # consecutive half-second hits before it counts (3 s): a passer-by fades, a crawling snake persists
samples = []           # [{t, h, c}] every 60s, 24h
def _hub_state():
    cfg, now = env(), time.time()
    def pick(key):
        r = latest.get(cfg.get(key, ""))
        return None if not r or now - r["seen"] > STALE_S else r
    today = time.mktime(time.localtime(now)[:3] + (0, 0, 0, 0, 0, -1))
    def hilo(k):
        v = [s[k] for s in samples if s["t"] >= today and s[k] is not None]
        return {"min": min(v), "max": max(v)} if v else None
    return {"hot": pick("SENSOR_HOT"), "cool": pick("SENSOR_COOL"), "unit": cfg.get("TEMP_UNIT", "F").upper(), "updated": now,
            "motion": {k: {**v, "moving": now - v.get("lastMove", 0) < 12} for k, v in motion.items()},
            "today": {"hot": hilo("h"), "cool": hilo("c")}, "samples": samples[-1440:], "activity": _activity(now)}
class Hub(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Access-Control-Allow-Headers", "content-type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS"); self.send_header("Access-Control-Allow-Private-Network", "true")
    def do_OPTIONS(self): self.send_response(204); self._cors(); self.end_headers()
    def do_GET(self):
        if self.path.split("?")[0] != "/state.json": self.send_response(404); self.end_headers(); return
        body = json.dumps(_hub_state()).encode(); self.send_response(200); self._cors()
        self.send_header("Content-Type", "application/json"); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        if self.path != "/motion": self.send_response(404); self.end_headers(); return
        try:
            d = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0) or b"{}")
            cam, score, now = str(d.get("cam", ""))[:16], float(d.get("score", 0)), time.time()
            m = motion.setdefault(cam, {"score": 0, "ts": 0, "lastMove": 0, "streak": 0}); m.update(score=score, ts=now)
            m["streak"] = m.get("streak", 0) + 1 if score >= MOVE_THRESHOLD else 0
            if m["streak"] >= MOVE_STREAK:
                if now - m.get("lastMove", 0) > 300: _bout(now, cam)      # a new bout after 5+ quiet minutes
                m["lastMove"] = now                              # sustained for MOVE_STREAK samples: a real move
            self.send_response(204)
        except Exception: self.send_response(400)
        self._cors(); self.end_headers()
# ---- activity history: when does she come out? ---------------------------------
BOUTS_FILE = f"{ROOT}/logs/activity.jsonl"
bouts = []
try: bouts = [json.loads(l) for l in open(BOUTS_FILE) if l.strip()]
except Exception: bouts = []
def _bout(now, cam):
    bouts.append({"t": now, "cam": cam})
    try:
        with open(BOUTS_FILE, "a") as f: f.write(json.dumps({"t": now, "cam": cam}) + "\n")
    except Exception: pass
def _activity(now):
    """Her routine from the bout log. One noisy day must not become a prediction: a bout counts at most once per
    hour per day, and the learned window is only used after MIN_DAYS distinct days with MIN_BOUTS such bouts.
    Until then the overlay falls back to 'after sunset', which is what ball pythons actually do."""
    recent = [b for b in bouts if now - b["t"] < 7 * 86400]
    seen = {}
    for b in recent:
        lt = time.localtime(b["t"]); seen[(lt.tm_yday, lt.tm_hour)] = 1
    hist = [0] * 24
    for (_, h) in seen: hist[h] += 1
    days_with = len({d for (d, _) in seen})
    out = {"bouts7d": len(recent), "boutsToday": sum(1 for b in recent if time.localtime(b["t"]).tm_yday == time.localtime(now).tm_yday), "daysWithActivity": days_with}
    days = max(1, days_with)
    per_hour = [h / days for h in hist]                       # share of active days on which she moved in that hour
    out["byHour"] = [round(x, 2) for x in per_hour]
    if len(seen) >= MIN_BOUTS and days_with >= MIN_DAYS:      # enough history: predict the next likely hour
        lt = time.localtime(now); h0 = lt.tm_hour; best = None
        for k in range(1, 25):
            h = (h0 + k) % 24
            if per_hour[h] >= 0.5: best = k; break
        if best is not None:
            t = time.mktime(lt[:3] + (h0 + best, 0, 0, 0, 0, -1))
            out["nextExpected"] = t
        peak = max(range(24), key=lambda h: per_hour[h]); win = [h for h in range(24) if per_hour[h] >= max(0.5, per_hour[peak] * 0.6)]
        if win: out["activeHours"] = win
    return out
def _hub():
    try: ThreadingHTTPServer(("127.0.0.1", HUB_PORT), Hub).serve_forever()
    except Exception as e: print("hub failed:", e, flush=True)
def _sampler():
    cfg = env()
    while True:
        now = time.time()
        def val(key):
            r = latest.get(cfg.get(key, "")); return None if not r or now - r["seen"] > STALE_S else r["f"]
        samples.append({"t": now, "h": val("SENSOR_HOT"), "c": val("SENSOR_COOL")})
        del samples[:-1440]
        try: json.dump(samples, open(f"{ROOT}/logs/samples.json", "w"))
        except Exception: pass
        time.sleep(60)
try:
    samples = [s for s in json.load(open(f"{ROOT}/logs/samples.json")) if time.time() - s["t"] < 86400]
except Exception: samples = []
threading.Thread(target=_hub, daemon=True).start(); threading.Thread(target=_sampler, daemon=True).start()

def on_adv(dev, adv):
    r = decode(adv.manufacturer_data)
    if r:
        name = adv.local_name or dev.name or dev.address
        latest[name] = {**r, "rssi": adv.rssi, "seen": time.time()}

def publish():
    cfg, now = env(), time.time()
    def pick(key):
        r = latest.get(cfg.get(key, ""))
        return None if not r or now - r["seen"] > STALE_S else r
    doc = {"hot": pick("SENSOR_HOT"), "cool": pick("SENSOR_COOL"),
           "unit": cfg.get("TEMP_UNIT", "F").upper(), "all": latest, "updated": now}
    for path, body in ((OUT_JS, "window.READINGS=" + json.dumps(doc) + ";"), (OUT_JSON, json.dumps(doc, indent=1))):
        tmp = path + ".tmp"
        with open(tmp, "w") as f: f.write(body)
        os.replace(tmp, path)

async def main():
    stop = asyncio.Event()
    for s in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(s, stop.set)
    # First launch: macOS shows the Bluetooth permission prompt and reports the
    # radio as unavailable until it's answered. Keep trying rather than dying.
    while not stop.is_set():
        try:
            scanner = BleakScanner(on_adv); await scanner.start(); break
        except BleakError as e:
            print(f"bluetooth not ready ({e}); retrying in 10s", flush=True)
            try: await asyncio.wait_for(stop.wait(), 10)
            except asyncio.TimeoutError: pass
    else:
        return
    print("listening for Govee beacons", flush=True)
    try:
        while not stop.is_set():
            publish()
            try: await asyncio.wait_for(stop.wait(), WRITE_EVERY)
            except asyncio.TimeoutError: pass
    finally:
        await scanner.stop()
    print("stopped", flush=True)

asyncio.run(main())
