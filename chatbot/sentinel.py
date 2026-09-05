#!/usr/bin/env python3
"""Chat sentinel: a read-only, anonymous Twitch IRC client (no token) that logs every message of the channel to logs/chat.jsonl.
The bot replays what arrived while it was restarting, so a restart never loses a viewer's request. Independent of the bot on purpose."""
import json, os, re, socket, ssl, time, random
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = dict(l.split("#")[0].strip().split("=", 1) for l in open(f"{ROOT}/.env") if "=" in l.split("#")[0])
CHANNEL = CFG["TWITCH_CHANNEL"].strip().lower(); LOG = f"{ROOT}/logs/chat.jsonl"; os.makedirs(f"{ROOT}/logs", exist_ok=True)
def run():
    nick = f"justinfan{random.randint(10000, 99999)}"
    s = ssl.create_default_context().wrap_socket(socket.create_connection(("irc.chat.twitch.tv", 6697), timeout=30), server_hostname="irc.chat.twitch.tv")
    s.sendall(f"CAP REQ :twitch.tv/tags\r\nNICK {nick}\r\nJOIN #{CHANNEL}\r\n".encode()); s.settimeout(400); buf = b""
    print(time.strftime("%H:%M:%S"), "sentinel joined #" + CHANNEL, flush=True)
    while True:
        data = s.recv(4096)
        if not data: raise ConnectionError("closed")
        buf += data
        while b"\r\n" in buf:
            line, buf = buf.split(b"\r\n", 1); line = line.decode("utf-8", "replace")
            if line.startswith("PING"): s.sendall(b"PONG :tmi.twitch.tv\r\n"); continue
            m = re.match(r"^(?:@(?P<tags>[^ ]+) )?:(?P<user>[^!]+)![^ ]+ PRIVMSG #(?P<chan>[^ ]+) :(?P<text>.*)$", line)
            if m:
                tags = dict(kv.split("=", 1) for kv in (m.group("tags") or "").split(";") if "=" in kv)
                rec = {"ts": int(tags.get("tmi-sent-ts", int(time.time() * 1000))) / 1000, "user": m.group("user"), "text": m.group("text"), "id": tags.get("id"), "tags": {k: tags.get(k) for k in ("display-name", "mod", "subscriber", "user-id") if k in tags}}
                open(LOG, "a").write(json.dumps(rec, ensure_ascii=False) + "\n")
while True:
    try: run()
    except Exception as e: print(time.strftime("%H:%M:%S"), "sentinel reconnecting:", str(e)[:80], flush=True); time.sleep(5)
