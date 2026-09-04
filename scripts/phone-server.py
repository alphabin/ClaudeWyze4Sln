#!/usr/bin/env python3
"""HTTPS server for the phone companion page (overlay/phone/), on the LAN, same self-signed cert as the rip-cam relay.
GET  /            -> the page        GET /status -> {ripcam, pull, cmd}        POST /cmd {"mode":"table|eagle","judge":true,"stop":true,"holo":true|false}   POST /shot <jpeg> -> judge that still
The bot reads overlay/phone_cmd.json. The page itself publishes the camera straight to the relay over WHIP (port 8891)."""
import http.server, json, os, ssl, time, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); WEB = f"{ROOT}/overlay/phone"; PORT = int(os.environ.get("PHONE_PORT", "8895"))
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=WEB, **k)
    def log_message(self, *a): pass
    def _json(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.send_header("Cache-Control", "no-store"); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/status"):
            out = {}
            for k, f in (("ripcam", "ripcam.json"), ("pull", "pull.json"), ("cmd", "phone_cmd.json"), ("rip", "rip_state.json")):
                try: out[k] = json.load(open(f"{ROOT}/overlay/{f}"))
                except Exception: out[k] = None
            try: out["queue"] = len([f for f in os.listdir(f"{ROOT}/overlay/shots") if f.endswith(".jpg")])
            except Exception: out["queue"] = 0
            return self._json(200, out)
        if self.path.startswith("/pull-image"):
            try:
                img = json.load(open(f"{ROOT}/overlay/pull.json"))["image"]; data = open(f"{ROOT}/overlay/{img}", "rb").read()
                self.send_response(200); self.send_header("Content-Type", "image/jpeg"); self.send_header("Content-Length", str(len(data))); self.send_header("Cache-Control", "no-store"); self.end_headers(); return self.wfile.write(data)
            except Exception: return self._json(404, {"error": "no image"})
        if self.path == "/": self.path = "/index.html"
        return super().do_GET()
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if self.path == "/shot":                                                   # the page snapped a sharp full-size still: judge this one
            if n > 12_000_000: return self._json(413, {"error": "too big"})
            data = self.rfile.read(n); ts = int(time.time() * 1000); os.makedirs(f"{ROOT}/overlay/shots", exist_ok=True); dst = f"{ROOT}/overlay/shots/{ts}.jpg"
            if not data.startswith(b"\xff\xd8"): return self._json(400, {"error": "not a jpeg"})
            open(dst + ".tmp", "wb").write(data); os.replace(dst + ".tmp", dst)           # the bot judges the queue in order and deletes each one
            cmd = {"judge": True, "shot": dst, "ts": ts // 1000}; json.dump(cmd, open(f"{ROOT}/overlay/phone_cmd.json", "w"))
            return self._json(200, {"ok": True, "queued": len([f for f in os.listdir(f"{ROOT}/overlay/shots") if f.endswith(".jpg")])})
        if self.path != "/cmd": return self._json(404, {"error": "no"})
        body = json.loads(self.rfile.read(n) or b"{}")
        cmd = {k: body[k] for k in ("mode", "judge", "stop", "holo") if k in body}; cmd["ts"] = int(time.time())
        json.dump(cmd, open(f"{ROOT}/overlay/phone_cmd.json", "w")); return self._json(200, {"ok": True, "cmd": cmd})
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(f"{ROOT}/relay/ripcam/certs/server.crt", f"{ROOT}/relay/ripcam/certs/server.key"); httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print("phone page on https://0.0.0.0:%d" % PORT, flush=True); httpd.serve_forever()
