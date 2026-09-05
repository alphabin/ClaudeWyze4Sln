#!/usr/bin/env python3
"""Chat sentinel: a read-only, anonymous Twitch IRC client (no token) that logs every message of the channel to logs/chat.jsonl.
The bot replays what arrived while it was restarting, so a restart never loses a viewer's request. Independent of the bot on purpose."""
import json, os, re, socket, ssl, time, random
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG = dict(l.split("#")[0].strip().split("=", 1) for l in open(f"{ROOT}/.env") if "=" in l.split("#")[0])
CHANNEL = CFG["TWITCH_CHANNEL"].strip().lower(); LOG = f"{ROOT}/logs/chat.jsonl"; os.makedirs(f"{ROOT}/logs", exist_ok=True)
NICK = CFG.get("TWITCH_BOT_NICK", CHANNEL).strip().lower(); IGNORE = {NICK, "nightbot", "streamelements", "moobot", "soundalerts", "wizebot"}
import threading
_pending = {}; _covered = {}; _voice = {"sock": None}
def token():
    try: return json.load(open(f"{ROOT}/chatbot/token.json"))["access_token"]
    except Exception: return None
def voice_send(text):
    """A second, authenticated connection used ONLY when the bot has gone quiet: the court never leaves a hello hanging."""
    tok = token()
    if not tok: return False
    try:
        v = ssl.create_default_context().wrap_socket(socket.create_connection(("irc.chat.twitch.tv", 6697), timeout=15), server_hostname="irc.chat.twitch.tv")
        v.sendall(f"PASS oauth:{tok}\r\nNICK {NICK}\r\nJOIN #{CHANNEL}\r\nPRIVMSG #{CHANNEL} :{text[:450]}\r\n".encode()); time.sleep(1.5); v.close()
        print(time.strftime("%H:%M:%S"), "voice ->", text[:100], flush=True); return True
    except Exception as e: print(time.strftime("%H:%M:%S"), "voice failed:", str(e)[:80], flush=True); return False
def watch_silence():
    """Every 5 s: a viewer message older than 75 s with no line from the bot addressed to them since -> the sentinel answers in her voice (once per viewer per 10 min)."""
    while True:
        time.sleep(5); now = time.time()
        for u, rec in list(_pending.items()):
            if now - rec["ts"] < 75: continue
            _pending.pop(u, None)
            if now - _covered.get(u, 0) < 600: continue
            _covered[u] = now
            first = ("hi", "hello", "hey", "yo", "sup", "hola", "good evening", "good morning", "good night")
            low = rec["text"].lower().strip("!. ")
            if low.startswith(first) and len(low.split()) <= 4:
                line = random.choice([f"@{u} hello {u}, welcome to my court. I was mid blink. Say tarot and I will read your cards, say haiku for a poem, or tell me what brought you here. 👑",
                                      f"@{u} {u}, you caught me between thoughts. Welcome. What would you like tonight: a tarot reading, a haiku, or just company?"])
            else:
                line = random.choice([f"@{u} forgive the pause, {u}, my scribe blinked. I am here. Say it once more and I will answer properly.",
                                      f"@{u} {u}, I heard you and I am slow tonight. Ask again, I am listening."])
            voice_send(line)
threading.Thread(target=watch_silence, daemon=True).start()
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
                u = rec["user"].lower()
                if u == NICK:                                                                  # a line from the bot: whoever it addresses is answered
                    for name in re.findall(r"@([a-z0-9_]+)", rec["text"].lower()): _pending.pop(name, None)
                elif u not in IGNORE and not rec["text"].startswith("!"): _pending[u] = {"ts": rec["ts"], "text": rec["text"]}
while True:
    try: run()
    except Exception as e: print(time.strftime("%H:%M:%S"), "sentinel reconnecting:", str(e)[:80], flush=True); time.sleep(5)
