# Quickstart: blank Mac to live on Twitch in about 20 minutes

One script does the work; you do the four things only a human can do. Every step is skipped when it is
already done, so re-run `./install.sh` as often as you like.

## Before you start (5 minutes, all in a browser)

Only you can do these four things. Have them ready and the install runs straight through.

| # | What | Where | Why |
|---|------|-------|-----|
| 1 | **Wyze API key pair** (Key Id + API Key) | https://developer-api-console.wyze.com/ (sign in with your Wyze account, *Create an API key*) | The bridge logs in to Wyze with your email, password and this key pair; the key pair is what gets around 2FA. |
| 2 | **Twitch developer app** (Client ID) | https://dev.twitch.tv/console/apps > *Register Your Application*: any name, OAuth redirect `http://localhost:3000`, category *Chat Bot*, client type **Public** | The chat bot and the stream watchdog talk to Twitch through it. No client secret is needed. |
| 3 | **Twitch stream key** | Creator Dashboard > Settings > Stream > *Primary Stream Key* | Pasted into OBS once; the installer stops and waits for it. |
| 4 | **Two device-code approvals** | The installer prints a link and a code each time | (a) the bot's Twitch login (`chatbot/auth.py`), approved in a browser signed in as the bot account; (b) the `claude` command's login to your Claude subscription (if you pick the `cli` backend). |

You also need: a Mac with Apple silicon, macOS 14 or newer, your Wyze cameras already set up in the Wyze
app, and (optional) one Govee H5075-class Bluetooth thermometer per side of the enclosure.

## The 20 minutes

```bash
git clone https://github.com/alphabin/ClaudeWyze4Sln.git
cd ClaudeWyze4Sln
./install.sh
```

What the installer does, in order (each step prints `[done]` when it is already satisfied):

0. **Preflight**: checks macOS/Apple silicon and the Xcode command line tools; installs Homebrew packages
   (`colima docker docker-compose mediamtx ffmpeg python@3.12 gh`), Google Chrome and OBS if missing;
   creates the bot's Python venv; installs `bleak` for the Bluetooth reader. If Homebrew belongs to another
   user it tells you the exact `chown` to run and stops.
1. **Runtime layout**: `.env` from `bridge/.env.example`, `docker-compose.yml`, and your own `overlay/`
   (copies of the players and the overlay pages; edit those, the originals in `players/` and
   `overlay-example/` stay pristine).
2. **Wyze credentials** (you type them, nothing is echoed): `bridge/setup-wyze.sh`.
3. **Docker**: `colima start`, `docker compose up -d`, then waits for the bridge on http://localhost:5050.
4. **Cameras**: lists what the bridge found and asks which one is the hot side and which the cool side.
5. **Pan V4 session**: waits for the provisioner to write `overlay/lake/<cool-cam>.json`. If your cool camera
   is not a Pan V4 it switches that decoder to the Kinesis player instead (`CAM_COLD_PATH=kvs`).
6. **Agora SDK**: downloads it once into `overlay/` (the bridge serves it locally).
7. **OBS**: installs the SnakeCam scene + profile and enables obs-websocket, opens OBS and waits while you
   paste the **stream key** (Settings > Stream), then quit OBS so it saves.
8. **Twitch bot**: asks for the app's **Client ID** and your channel name, then runs the device-code login
   (open the link as the bot account, enter the code). The bot may simply be your channel account.
9. **Sensors**: builds the small signed `SnakeSensors.app` (macOS needs a real app for Bluetooth), scans for
   Govee beacons for 15 s and asks which is hot and which is cool. Hold one in your hand to tell them apart.
10. **Location**: latitude/longitude (city-level) for weather, sunrise and sunset.
11. **Claude backend**: `cli` (the `claude` command with your subscription; sign in when asked), `api`
    (an Anthropic API key), or `off` (templates only, zero cost).
12. **launchd**: installs the seven agents and loads each one whose prerequisites are met. From here on
    everything starts at login and restarts on crash.
13. **Unattended Mac** reminders: auto-login as this user, never sleep, restart after power failure,
    FileVault off.
14. **Doctor**: `./doctor.sh` runs and shows PASS/WARN/FAIL for every layer.

Give the cameras a minute after step 12. OBS appears in the menu bar (tray-only); your Twitch page shows
LIVE within about 30 seconds of OBS starting.

## Afterwards

```bash
./doctor.sh              # every layer, with a one-line fix per WARN/FAIL; exit code = number of FAILs
./install.sh --check     # what the installer would still do (changes nothing)
./bridge/discover.sh     # camera names and which path each one takes
scripts/feed.sh ate      # feeding log for the overlay (ate | refused | shed | plan DATE | interval N)
```

Double-click `scripts/Start Snakecam.command` / `Stop Snakecam.command` in Finder to bring the whole
stream up or take it off air. Logs live in `~/Library/Logs/snakecam-*.log`.

Reboot test: restart the Mac and touch nothing. With auto-login set, Twitch shows LIVE again within
about two minutes.

## If something is red

`doctor.sh` prints the fix next to each FAIL. The layers fail independently, so a red line points at exactly
one part: Docker/bridge (Wyze login), provisioner (Pan V4 session), relay, a decoder (headless Chrome),
sensors, OBS, Twitch, or the bot. `WRITEUP.md` section 8 covers the camera-side problems in depth.

## Flags

- `./install.sh --check`: report only.
- `./install.sh --yes`: no questions; anything that needs you is left as `[todo]`.
- `./install.sh --root DIR` / `SNAKECAM_ROOT=DIR`: keep `.env`, `overlay/`, `tokens/`, `logs/` somewhere other
  than the kit folder (the kit is then linked in). `doctor.sh` takes the same flag.
