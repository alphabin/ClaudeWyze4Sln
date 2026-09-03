#!/usr/bin/env python3
"""
One-time Twitch authorization for the chat bot (device-code flow: no secrets, no redirect server).
Run it in Terminal, open the link it prints while signed in as the BOT account, enter the code.
Tokens are saved to chatbot/token.json and refreshed automatically by the bot afterwards.

  chatbot/.venv/bin/python chatbot/auth.py
Needs TWITCH_CLIENT_ID in ../.env (from https://dev.twitch.tv/console/apps, client type Public).
"""
import json, os, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
SCOPES = "chat:read chat:edit moderator:read:followers channel:read:subscriptions clips:edit"   # channel:read:subscriptions: sub count for the Pokémon rip goal

def env():
    d = {}
    try:
        for line in open(f"{ROOT}/.env"):
            line = line.split("#", 1)[0].strip()
            if "=" in line: k, v = line.split("=", 1); d[k.strip()] = v.strip().strip('"')
    except FileNotFoundError: pass
    return d

def post(url, data):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=20) as r: return r.status, json.load(r)
    except urllib.error.HTTPError as e: return e.code, json.load(e)

def main():
    cid = env().get("TWITCH_CLIENT_ID")
    if not cid: sys.exit("TWITCH_CLIENT_ID is missing from .env")
    st, d = post("https://id.twitch.tv/oauth2/device", {"client_id": cid, "scopes": SCOPES})
    if st != 200: sys.exit(f"device code request failed: {d}")
    print("\n1. Open this link in a browser where you are signed in as the BOT account:")
    print("   ", d["verification_uri"])
    print("2. Enter the code:", d["user_code"], "\n")
    print("Waiting for you to authorize…")
    while True:
        time.sleep(d.get("interval", 5))
        st, t = post("https://id.twitch.tv/oauth2/token", {"client_id": cid, "device_code": d["device_code"],
                                                          "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        if st == 200:
            t["obtained"] = int(time.time())
            json.dump(t, open(f"{HERE}/token.json", "w")); os.chmod(f"{HERE}/token.json", 0o600)
            # who did we log in as?
            req = urllib.request.Request("https://id.twitch.tv/oauth2/validate", headers={"Authorization": "OAuth " + t["access_token"]})
            who = json.load(urllib.request.urlopen(req, timeout=20))
            login = who.get("login", "")
            envp = f"{ROOT}/.env"; lines = open(envp).read().split("\n")
            lines = [f"TWITCH_BOT_NICK={login}" if l.startswith("TWITCH_BOT_NICK=") else l for l in lines]
            if not any(l.startswith("TWITCH_BOT_NICK=") for l in lines): lines.append(f"TWITCH_BOT_NICK={login}")
            open(envp, "w").write("\n".join(lines))
            print(f"\nAuthorized as {login} — saved chatbot/token.json and set TWITCH_BOT_NICK={login} in .env.")
            print("Start the bot:  launchctl load ~/Library/LaunchAgents/com.snakecam.chatbot.plist   (or double-click Start Snakecam)")
            return
        msg = t.get("message", "")
        if "authorization_pending" in msg or "slow_down" in msg: continue
        sys.exit(f"authorization failed: {t}")

if __name__ == "__main__": main()
