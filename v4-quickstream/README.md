# v4-quickstream — just the Pan V4 as a local stream

You have a **Wyze Cam Pan V4 (HL_PAN4)**, docker-wyze-bridge says `IOTC_ER_UNLICENSE` and shows no
video, and you only want the camera as an **RTSP / WebRTC stream on your own machine** for OBS, VLC,
Home Assistant, Frigate, ffmpeg. Nothing else from this repository: no Twitch, no overlay, no bot.

This folder is that, self-contained. One script, two containers, two native processes.

    camera -> Wyze/Agora cloud -> headless Chrome (decodes H.265, re-encodes H.264) -> WHIP -> mediamtx
                                                              rtsp://127.0.0.1:8555/<cam>   http://localhost:8890/<cam>/

Why it looks like this: the Pan V4 has no direct (TUTK) service, only the Agora "lake" path that Wyze's
own web viewer uses, and it sends H.265 only. The full story is in [../WRITEUP.md](../WRITEUP.md).

## The 15-minute path

1. Install: Docker (Desktop or Colima), **Google Chrome 130 or newer** (Chromium on Linux), `mediamtx`, `ffmpeg`.
   macOS: `brew install --cask docker google-chrome && brew install mediamtx ffmpeg`.
   The script checks each and prints the install hint for anything missing.
2. Get an API key pair at https://developer-api-console.wyze.com/ (Key Id + API Key; it is what gets around 2FA).
3. Run it:

       git clone https://github.com/alphabin/ClaudeWyze4Sln && cd ClaudeWyze4Sln/v4-quickstream
       ./quickstream.sh

   It asks for your Wyze email/password/Key Id/API Key once (saved to `.env`, mode 600, never leaves this
   folder), downloads the Agora Web SDK, starts the bridge + provisioner, waits for the camera list, marks
   which cameras are "lake", asks which to stream (or takes them as arguments: `./quickstream.sh start my-cam`),
   fetches an Agora session, starts mediamtx and one headless Chrome per camera, then **proves it** by grabbing
   a still with ffmpeg from the RTSP URL (saved to `logs/<cam>.jpg`) and prints:

       my-cam
         RTSP            rtsp://<host>:8555/my-cam
         WebRTC viewer   http://localhost:8890/my-cam/
         OBS             Media Source, untick "Local File", Input = the RTSP URL, Input Format = rtsp
         VLC             File > Open Network > the RTSP URL
         Home Assistant  camera: - platform: generic   stream_source: rtsp://<host>:8555/my-cam

   First frames take 20-60 s (the camera has to be woken over the Agora data stream).

Afterwards:

    ./quickstream.sh status     # frames advancing? (asks the headless Chrome over its debug port)
    ./quickstream.sh stop       # stop decoder(s) + mediamtx; containers keep the login alive
    ./quickstream.sh down       # ...and the containers
    ./quickstream.sh logs       # mediamtx + decoder logs (./logs)
    ./quickstream.sh login      # change the Wyze credentials

Several Pan V4s: pick them all (or `start cam-a cam-b`); each gets its own Chrome (debug ports 9224, 9225, ...)
and its own path on the relay. The camera list uses the bridge's names (nickname lowercased, dashes).

Keep the machine awake (macOS: `caffeinate -s` or Energy Saver). To run it at boot, wrap
`quickstream.sh start <cam>` in a LaunchAgent / systemd unit; `../launchd/` has the plists the full kit uses.

## What the ports are

| Port | What | Bound to |
|---|---|---|
| 5050 | wyze-bridge web UI + the player page (`/static/quickstream/lake.html`) | 127.0.0.1 only (no auth) |
| 5051 | lake-provisioner: `POST /provision/<cam>` returns a fresh Agora session | 127.0.0.1 only |
| 8555 | mediamtx RTSP (TCP) | all interfaces: your LAN can pull it |
| 8890 | mediamtx WebRTC (WHIP in from Chrome, WHEP/viewer page out) | all interfaces |
| 9224+ | Chrome DevTools of decoder n (what `status` talks to) | localhost |

Nothing here is exposed to the internet unless you forward it yourself.

## Caveats you should know before you rely on it

- **H.265 and OBS.** The camera only sends H.265. Chrome >= 130 decodes it in WebRTC; OBS's embedded browser
  (CEF 127) does not (`RECV_VIDEO_DECODE_FAILED`). That is why there is a headless Chrome and a relay at all:
  in OBS use a **Media Source on the RTSP URL**, never a Browser Source on `lake.html`. The relay stream is
  H.264 at up to 1080p (Chrome re-encodes; the camera-side request is `2k`, set `RES=HD ./quickstream.sh`
  to ask for less).
- **One client per session.** Each Agora session id serves exactly one client. Opening `lake.html` in a
  second tab, or running two decoders for the same camera, bans the first one (`UID_BANNED`). Use the relay
  (`:8555` / `:8890`) for every viewer; it has no such limit.
- **Video only.** `lake.html` subscribes to the camera's audio and plays it inside the page, but only the
  **video** track is pushed over WHIP, so the RTSP/WebRTC stream has no audio track.
- **Cloud-dependent.** camera -> Wyze/Agora -> you. No Wyze cloud, no picture. The provisioner uses the
  web app's public `appid`/secret constants; Wyze can change them (see WRITEUP section 5 and 10).
- **Hourly renewal.** Sessions live 3600 s; the sidecar renews them and the player reloads on
  `token-privilege-will-expire`. Expect a 5-10 s hiccup around each renewal.
- The bridge logs `IOTC_ER_UNLICENSE` for the V4. That is expected: ignore it.

## What it does NOT do

- **PTZ / cruise / motion tracking.** Pan/tilt does not ride this path; keep using the Wyze app for that
  (pause the stream for a minute while you change presets, the camera serves one session at a time).
- **Audio** in the relay (see above), two-way talk, motion events, sirens, spotlight.
- Other camera models. Cameras the bridge *can* reach (V2/V3/Pan V3, ...) already stream from the bridge
  itself on its own RTSP port; the full kit's `players/cam.html` covers their Kinesis path. This folder
  deliberately only handles `HL_PAN4`-class ("lake") cameras.
- Recording, motion detection, cloud clips, Twitch, overlays, chat bot — that is the rest of the repository.

## Troubleshooting

Run `./quickstream.sh status` first; it prints decoded frames, the WHIP state and the player's last messages.

| Symptom | Look at |
|---|---|
| Script stops at "waiting for the bridge" | `docker compose logs wyze-bridge`: wrong password/API key -> `./quickstream.sh login`, then `docker compose up -d --force-recreate` |
| "no session for <cam>" | `docker compose logs lake-provisioner`; Wyze does not list the camera as `lake` (WRITEUP section 1, 8) |
| Joined but "camera did not join within 30s" | Camera asleep/offline, or someone else (the Wyze app, another tab) holds the session. WRITEUP section 4 |
| `UID_BANNED` in the decoder log | A second client on the same session: close the other tab/decoder. WRITEUP section 8 |
| Frames not advancing, everything "connected" | Stale media session on the camera; the player reboots it via the bridge after 3 stalled checks (WRITEUP section 9). Or reboot it from the Wyze app |
| mediamtx "no stream on path", relay drops every 20 s | An unscaled 4K frame hit the encoder; fixed in this `lake.html`, make sure you are on the current copy. WRITEUP section 9 |
| Picture stuck at 640x360 | The camera ignored the resolution request; the page re-asks every 4 s. WRITEUP section 8 |
| Works an hour, then dies | Provisioner not running (`docker compose ps`). WRITEUP section 8 |
| Colima: `tokens/` stays empty / mount errors | Colima only shares your home directory by default; clone this into `~` or add the path to `~/.colima/default/colima.yaml` mounts |
| Linux: Chrome not found | The script looks for `google-chrome`, `google-chrome-stable`, `chromium`, `chromium-browser` on PATH and says which one it uses |
| Port 8555/8890 in use | Another mediamtx (the full kit's relay uses the same ports) — stop it, or edit `mediamtx.yml` and the ports at the top of `quickstream.sh` |

More: [../WRITEUP.md section 8 (Troubleshooting)](../WRITEUP.md#8-troubleshooting) and
[section 9 (24/7 lessons)](../WRITEUP.md#9-running-it-247--what-we-learned-after-a-day-on-air).

## Files

    quickstream.sh       the one command (start / status / stop / down / logs / login / cams)
    docker-compose.yml   wyze-bridge + lake-provisioner, trimmed from ../bridge/docker-compose.yml
    provision.py         the provisioner sidecar (copy of ../lake/provision.py)
    mediamtx.yml         the relay config (copy of ../relay/mediamtx.yml)
    www/lake.html        the Agora player with WHIP relay mode (../players/lake.html minus the snakecam motion reporter)
    www/get-agora-sdk.sh downloads agora-rtc-sdk.js (Agora's SDK is not redistributed here)
    runtime (git-ignored): .env, tokens/, www/lake/<cam>.json, logs/, run/ (pidfiles, Chrome profiles)

Licence and credits: see the repository root. The camera, the account and the calls are yours; this only
reproduces what Wyze's own web viewer does (WRITEUP section 10).
