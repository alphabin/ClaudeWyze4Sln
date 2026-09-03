#!/bin/bash
# Lists the cameras the bridge found and the exact stream names to put in .env
python3 - <<'PY' || echo "bridge not reachable at :5000 - is it running? (docker compose ps)"
import json, urllib.request, sys
try: cams = json.load(urllib.request.urlopen("http://localhost:5050/api", timeout=5))
except Exception as e: sys.exit(1)
for name, c in cams.items():
    state = "ONLINE" if c.get("connected") else "offline"
    print(f"{name:<18} model={str(c.get('product_model','?')):<10} ip={str(c.get('ip') or '?'):<16} {state}")
PY
