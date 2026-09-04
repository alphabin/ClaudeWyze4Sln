#!/usr/bin/env python3
"""Build chatbot/prices.json from tcgcsv.com (free daily dump of TCGplayer prices, Pokémon category 3). Run daily (the bot also refreshes it when older than 24 h)."""
import json, os, sys, time, urllib.request
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); OUT = f"{ROOT}/chatbot/prices.json"; UA = {"User-Agent": "snakecam-cleobot/1.0 (price index)"}
def get(u):
    for i in range(3):
        try: return json.load(urllib.request.urlopen(urllib.request.Request(u, headers=UA), timeout=60)).get("results", [])
        except Exception as e:
            if i == 2: raise
            time.sleep(3)
groups = get("https://tcgcsv.com/tcgplayer/3/groups"); rows = []; t0 = time.time()
for i, g in enumerate(groups):
    gid, gname = g["groupId"], g["name"]
    try: prods = get(f"https://tcgcsv.com/tcgplayer/3/{gid}/products"); prices = get(f"https://tcgcsv.com/tcgplayer/3/{gid}/prices")
    except Exception as e: print("skip", gname, e, file=sys.stderr); continue
    pm = {}
    for p in prices:
        if p.get("marketPrice"): pm.setdefault(p["productId"], []).append((p.get("subTypeName") or "", p["marketPrice"]))
    for p in prods:
        if p["productId"] not in pm: continue
        ext = {e["name"]: e["value"] for e in p.get("extendedData", [])}
        best = max(pm[p["productId"]], key=lambda x: x[1])
        rows.append({"n": p["name"].split(" - ")[0].strip(), "num": (ext.get("Number") or "").strip(), "set": gname, "r": ext.get("Rarity") or "", "sub": best[0], "m": round(best[1], 2), "sealed": not ext.get("Number") and not ext.get("Rarity")})
    time.sleep(0.15)
json.dump({"built": int(time.time()), "rows": rows}, open(OUT, "w"))
print(f"{len(rows)} priced products from {len(groups)} sets in {time.time() - t0:.0f}s -> {OUT}")
