import asyncio, sys, time
from bleak import BleakScanner

GOVEE = 0xEC88          # manufacturer id used by H5072/H5075
seen = {}

def decode(mfr):
    raw = mfr.get(GOVEE)
    if not raw or len(raw) < 5: return None
    v = int.from_bytes(raw[1:4], "big")
    neg = bool(v & 0x800000); v &= 0x7FFFFF
    temp = v / 10000 * (-1 if neg else 1)
    hum  = (v % 1000) / 10
    return round(temp,1), round(temp*9/5+32,1), hum, raw[4]

def cb(dev, adv):
    name = adv.local_name or dev.name or "?"
    d = decode(adv.manufacturer_data)
    if d:
        seen[name] = (d, adv.rssi, dev.address, time.strftime("%H:%M:%S"))
    elif name.startswith("GV") or "Govee" in name:
        seen[name] = (("no-decode", adv.manufacturer_data), adv.rssi, dev.address, "")

async def main():
    sc = BleakScanner(cb)
    await sc.start(); await asyncio.sleep(15); await sc.stop()
    if not seen: print("no Govee beacons heard in 15s"); return
    for n,(d,rssi,addr,t) in sorted(seen.items()):
        if d[0]=="no-decode": print(f"{n:<18} rssi={rssi:>4}  UNDECODED mfr={ {hex(k):v.hex() for k,v in d[1].items()} }"); continue
        tc,tf,h,b = d
        print(f"{n:<18} {tc}°C / {tf}°F   {h}% RH   batt {b}%   rssi {rssi} dBm   id {addr}   @{t}")

asyncio.run(main())
