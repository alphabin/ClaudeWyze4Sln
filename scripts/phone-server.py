#!/usr/bin/env python3
"""HTTPS server for the phone companion page (overlay/phone/), on the LAN, same self-signed cert as the rip-cam relay.
GET  /            -> the page        GET /status -> {ripcam, pull, cmd}        POST /cmd {"mode":"table|eagle|auto","judge":true,"stop":true}
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
            return self._json(200, out)
        if self.path == "/": self.path = "/index.html"
        return super().do_GET()
    def do_POST(self):
        if self.path != "/cmd": return self._json(404, {"error": "no"})
        n = int(self.headers.get("Content-Length") or 0); body = json.loads(self.rfile.read(n) or b"{}")
        cmd = {k: body[k] for k in ("mode", "judge", "stop") if k in body}; cmd["ts"] = int(time.time())
        json.dump(cmd, open(f"{ROOT}/overlay/phone_cmd.json", "w")); return self._json(200, {"ok": True, "cmd": cmd})
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(f"{ROOT}/relay/ripcam/certs/server.crt", f"{ROOT}/relay/ripcam/certs/server.key"); httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print("phone page on https://0.0.0.0:%d" % PORT, flush=True); httpd.serve_forever()
