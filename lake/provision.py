#!/usr/bin/env python3
"""
Wyze "lake" (Agora) session provisioner for cameras the bridge cannot stream directly
(Wyze Cam Pan V4 and other H.265-era models).

Does exactly what Wyze's own web viewer does, using the bridge's saved login:
  1. POST app/v4/camera/get-streams (provider "lake")  -> channel + encrypted key/salt
  2. POST app/v4/wcsa/create-connection                -> Agora app id, uids, RTC token
  3. unwrap key/salt (XXTEA, keyed with the login token) and write /out/<cam>.json
  4. renew the token before it expires and rewrite the file

Runs as a sidecar container next to the bridge (see docker-compose.yml) sharing /tokens.
Never logs token or key values.
"""
import hashlib, hmac, json, os, pickle, random, struct, sys, time, traceback
import requests
sys.path.insert(0, "/app")   # the bridge's own package (wyzecam) lives here; the pickles reference its classes

TOKENS = os.environ.get("TOKENS_DIR", "/tokens")
OUT = os.environ.get("OUT_DIR", "/out")
CAMS = [c.strip() for c in os.environ.get("LAKE_CAMS", "").split(",") if c.strip()]   # nicknames or macs; empty = all "lake" cams
RENEW_EVERY = int(os.environ.get("RENEW_EVERY", "2700"))                              # seconds; token life is 3600
APPID, SECRET = "strv_e7f78e9e7738dc50", "gbJojEBViLklgwyyDikx5ztSvKBXI5oU"          # Wyze web app identity (public constants in its JS)
API = "https://app.wyzecam.com"

def log(*a): print(time.strftime("%H:%M:%S"), *a, flush=True)

# ---- Wyze web-app request signing: signature2 = HmacMD5(body, MD5(token + secret)) ----
def signed_post(token, path, body, appinfo="wyze_web_2.3.1"):
    s = json.dumps(body, separators=(",", ":"))
    key = hashlib.md5((token + SECRET).encode()).hexdigest()
    h = {"content-type": "application/json", "appinfo": appinfo, "appid": APPID,
         "signature2": hmac.new(key.encode(), s.encode(), hashlib.md5).hexdigest(),
         "requestid": str(random.randint(10**8, 10**9)), "access_token": token, "Authorization": token}
    r = requests.post(API + path, data=s, headers=h, timeout=25)
    j = r.json()
    if str(j.get("code")) != "1":
        raise RuntimeError(f"{path} -> HTTP {r.status_code} code={j.get('code')} msg={j.get('msg')}")
    return j["data"]

# ---- XXTEA (as used by the xxtea-js package the web app bundles) ----------------------
_DELTA = 0x9E3779B9
def _to_u32(b, include_len):
    n = len(b); words = (n + 3) // 4
    v = list(struct.unpack("<%dI" % words, b + b"\0" * (words * 4 - n)))
    if include_len: v.append(n)
    return v
def _to_bytes(v, include_len):
    n = len(v) * 4
    if include_len:
        m = v[-1]
        if m < n - 7 or m > n - 4: return None
        n = m
    return struct.pack("<%dI" % len(v), *v)[:n]
def xxtea_decrypt(data: bytes, key: bytes) -> bytes:
    key = (key + b"\0" * 16)[:16]
    k = _to_u32(key, False); v = _to_u32(data, False); n = len(v)
    if n < 2: return data
    q = 6 + 52 // n; s = (q * _DELTA) & 0xFFFFFFFF
    y = v[0]
    while s:
        e = (s >> 2) & 3; z = v[n - 1]
        for p in range(n - 1, 0, -1):
            z = v[p - 1]
            mx = (((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((s ^ y) + (k[(p & 3) ^ e] ^ z))
            y = v[p] = (v[p] - mx) & 0xFFFFFFFF
        z = v[n - 1]
        mx = (((z >> 5) ^ (y << 2)) + ((y >> 3) ^ (z << 4))) ^ ((s ^ y) + (k[(0 & 3) ^ e] ^ z))
        y = v[0] = (v[0] - mx) & 0xFFFFFFFF
        s = (s - _DELTA) & 0xFFFFFFFF
    out = _to_bytes(v, True)
    if out is None: raise ValueError("xxtea: bad length word (wrong key?)")
    return out
def unwrap(b64: str, token: str) -> str:
    import base64
    return xxtea_decrypt(base64.b64decode(b64), token.encode()).decode("utf-8")

# ---- main loop --------------------------------------------------------------------------
def load_auth():
    auth = pickle.load(open(f"{TOKENS}/auth.pickle", "rb"))
    user = None
    try: user = pickle.load(open(f"{TOKENS}/user.pickle", "rb"))
    except Exception: pass
    user_id = getattr(user, "user_id", None) or getattr(auth, "user_id", None) or ""
    return auth.access_token, user_id

def cam_list():
    cams = pickle.load(open(f"{TOKENS}/cameras.pickle", "rb"))
    out = []
    for c in cams:
        d = c if isinstance(c, dict) else c.__dict__
        out.append({"mac": d.get("mac"), "model": d.get("product_model"), "name": d.get("nickname", "")})
    return out

def slug(name): return name.lower().replace(" ", "-")

def provision(token, user_id, cam):
    mac, model = cam["mac"], cam["model"]
    streams = signed_post(token, "/app/v4/camera/get-streams",
                          {"device_list": [{"device_id": mac, "device_model": model, "provider": "lake",
                                            "parameters": {"use_trickle": True}}], "nonce": int(time.time() * 1000)})
    p = streams[0]["params"]
    conn = signed_post(token, "/app/v4/wcsa/create-connection",
                       {"nonce": int(time.time() * 1000), "device_id": mac, "device_model": model, "mode": 3,
                        "uid": random.randint(10000, 99999), "expire_time": 3600, "resolution": 2}, "wyze_web_3.3.5")
    return {"cam": slug(cam["name"]), "mac": mac, "model": model, "user_id": user_id,
            "channel": p["channel"], "encryption_mode": p.get("encryption_mode", 0),
            "encryption_key": unwrap(p["encryption_key"], token) if p.get("encryption_key") else "",
            "encryption_salt": unwrap(p["encryption_salt"], token) if p.get("encryption_salt") else "",
            "app_id": conn["app_id"], "uid": conn["uid"], "device_uid": conn["device_uid"],
            "rtc_token": conn["rtc_token"], "issued": int(time.time()), "expires": int(time.time()) + 3600}

def write(sess):
    os.makedirs(OUT, exist_ok=True)
    tmp = f"{OUT}/{sess['cam']}.json.tmp"
    json.dump(sess, open(tmp, "w")); os.replace(tmp, f"{OUT}/{sess['cam']}.json")

# ---- on-demand endpoint: the player calls POST /provision/<cam> on every (re)start ------------------
# create-connection is what makes the camera join the Agora channel, so a cached session is not enough.
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
_last = {}
class OnDemand(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "content-type"); self.send_header("Access-Control-Allow-Private-Network", "true")
    def do_OPTIONS(self): self.send_response(204); self._cors(); self.end_headers()
    def do_POST(self):
        want = self.path.rstrip("/").split("/")[-1]
        try:
            token, user_id = load_auth()
            cam = next((c for c in cam_list() if slug(c["name"]) == want or c["mac"] == want), None)
            if not cam: self.send_response(404); self._cors(); self.end_headers(); return
            if time.time() - _last.get(want, 0) < 15:                     # don't hammer Wyze on a retry loop
                sess = json.load(open(f"{OUT}/{want}.json"))
            else:
                sess = provision(token, user_id, cam); write(sess); _last[want] = time.time(); log(f"{want}: fresh session on request")
            body = json.dumps(sess).encode(); self.send_response(200); self._cors()
            self.send_header("Content-Type", "application/json"); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(body)
        except Exception as e:
            log(f"{want}: on-demand provisioning failed: {e}"); self.send_response(502); self._cors(); self.end_headers()
def _serve():
    try: ThreadingHTTPServer(("0.0.0.0", int(os.environ.get("ONDEMAND_PORT", "5051"))), OnDemand).serve_forever()
    except Exception as e: log("on-demand server failed:", e)

def main():
    threading.Thread(target=_serve, daemon=True).start()
    log("lake provisioner starting; out:", OUT)
    while True:
        try:
            token, user_id = load_auth()
            cams = [c for c in cam_list() if (not CAMS or c["name"] in CAMS or c["mac"] in CAMS or slug(c["name"]) in CAMS)]
            for cam in cams:
                try:
                    s = provision(token, user_id, cam); write(s)
                    log(f"{s['cam']}: session ok (channel {s['channel'][:8]}…, key {len(s['encryption_key'])} chars, salt {len(s['encryption_salt'])} chars, token {len(s['rtc_token'])} chars, uid {s['uid']}, device_uid {s['device_uid']})")
                except Exception as e:
                    log(f"{cam['name']}: provisioning failed: {e}")
        except Exception:
            log("provisioner error:"); traceback.print_exc()
        time.sleep(RENEW_EVERY)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--once":
        RENEW_EVERY = 0
        token, user_id = load_auth()
        for cam in cam_list():
            if CAMS and not (cam["name"] in CAMS or cam["mac"] in CAMS or slug(cam["name"]) in CAMS): continue
            try: s = provision(token, user_id, cam); write(s); log(f"{s['cam']}: ok")
            except Exception as e: log(f"{cam['name']}: failed: {e}")
    else:
        main()
