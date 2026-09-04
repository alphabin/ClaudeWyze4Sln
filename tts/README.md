# The Oracle's voice (free, local)

Readings, fortunes, poems, camera observations and pack-rip announcements are spoken. Two engines:

1. **Piper** (recommended, free, neural, runs on the Mac in ~1 s per sentence):
   ```bash
   python3 -m venv tts/.venv && tts/.venv/bin/pip install piper-tts
   mkdir -p tts/voices && cd tts/voices
   for f in en_GB-alba-medium.onnx en_GB-alba-medium.onnx.json; do
     curl -sL -A "snakecam" -o $f "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/alba/medium/$f"; done
   ```
   Other voices: browse https://huggingface.co/rhasspy/piper-voices/tree/main/en and set `CLEOBOT_PIPER_VOICE=<name>` in `.env`.
   `CLEOBOT_PIPER_LENGTH` (1.08, higher = slower) and `CLEOBOT_PIPER_PAUSE` (0.35 s between sentences) shape the delivery.
2. **macOS `say`** is the automatic fallback when Piper isn't installed (`CLEOBOT_VOICE=Moira`, `CLEOBOT_VOICE_RATE=145`).

`CLEOBOT_VOICE_ON=0` mutes her. The bot writes `overlay/voice/<ts>.m4a` + `overlay/voice.json`; `ambience.html` plays it with a warm EQ and one echo tap while the music bed ducks.
