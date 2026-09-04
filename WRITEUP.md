# How Wyze's web viewer streams "unsupported" cameras (Pan V4 / HL_PAN4), and how to reproduce it

*For docker-wyze-bridge issue #1541 (IOTC_ER_UNLICENSE on HL_PAN4). Everything below was captured
from a logged-in session of my.wyze.com (build 76K3jFP9rQw3ELrol2XTL) on 2026-09-02 and reproduced
with the bridge's own saved login. Working code: `lake/provision.py`, `players/lake.html`.*

## 1. The camera isn't broken — it's on a different service

`POST https://app-core.cloud.wyze.com/app/v4/home/get-home-devices` returns per device
`device_param.p2p.providers`. Older cameras: `["tutk","webrtc"]`. HL_PAN4 (fw 4.70.3.4024): `["lake"]`.
There is no TUTK for it at all, which is why every TUTK attempt ends in `IOTC_ER_UNLICENSE`, and
Kinesis signaling is issued but never answered (the camera never joins that channel).

"lake" is Wyze's name for **Agora RTC**. The web viewer bundles Agora Web SDK NG 4.24.0 and joins an
Agora channel per camera.

## 2. Provisioning — two signed calls

Both to `https://app.wyzecam.com`, both with these headers:

    appid: strv_e7f78e9e7738dc50          (the web app's id)
    appinfo: wyze_web_2.3.1               (get-streams) / wyze_web_3.3.5 (create-connection)
    requestid: <random int>
    access_token: <token>   Authorization: <token>
    signature2: HmacMD5( body_json, MD5( token + "gbJojEBViLklgwyyDikx5ztSvKBXI5oU" ) )   (hex)

The token is an ordinary Wyze access token — the bridge's cached one works. The secret is a constant
in Wyze's web bundle (`_app-*.js`, keyed per host; this one covers app.wyzecam.com / app-core).

**a)** `POST /app/v4/camera/get-streams`

    {"device_list":[{"device_id":"<mac>","device_model":"HL_PAN4","provider":"lake","parameters":{"use_trickle":true}}],"nonce":<ms>}
    -> data[0].params = { channel, protocol: 3, encryption_mode: 7, encryption_key: <b64>, encryption_salt: <b64> }

**b)** `POST /app/v4/wcsa/create-connection`

    {"nonce":<ms>,"device_id":"<mac>","device_model":"HL_PAN4","mode":3,"uid":<random>,"expire_time":3600,"resolution":2}
    -> data = { app_id, uid, device_uid: 1, rtc_token, p2p_mode: true }

`/app/v4/wcsa/renew-token` (`{nonce, device_id, device_model, uid, expire_time}`) refreshes the token.
There is also `/app/v4/device/wakeup` (`{nonce, device_id, device_model, params:{mode:3,user_id,rtc_client_uid}}`),
only used for battery cameras.

## 3. The key and salt are wrapped

`encryption_key` / `encryption_salt` are **XXTEA-encrypted with the access token** (xxtea-js semantics:
key = first 16 bytes of the token, little-endian words, length word appended), then base64.
Decrypt both; the key becomes a string, the salt (base64 of 32 bytes) becomes a `Uint8Array`. Then:

    client.setEncryptionConfig(mode === 7 ? "aes-128-gcm2" : "aes-256-gcm2", key, saltBytes, /*encryptDataStream*/ false)

(`false` for HL_PAN4, HL_CAM3P, GW_*, ME_WCO3; the web app keeps a list.)

## 4. Joining and waking the camera

    client = AgoraRTC.createClient({ mode: "rtc", codec: "h265" /* or h264 */, audioCodec: "pcmu" })
    await client.join(app_id, channel, rtc_token, uid)

The camera does **not** publish until it receives, over the Agora data stream, a JSON array encoded as
UTF-8 bytes via `client.sendStreamMessage(...)`:

    [{"cmd":"run_action","action":"sight-safe::check-user","params":{"userId":"<wyze user_id>"}}]

Repeat every few seconds until `user-published` arrives for `device_uid` (1). Then subscribe and play.
Resolution is set the same way; the web app defaults to the lowest:

    [{"cmd":"set_property","props":{"camera::resolution":"360p"}}]      // values: 360p | SD | HD | 2k

## 5. Things that bit us

- **HL_PAN4 sends H.265 only.** Chromium ≥ 130 decodes it in WebRTC; OBS's CEF (127) does not
  (`RECV_VIDEO_DECODE_FAILED`). Decode in a real/headless Chrome and re-publish (WHIP → mediamtx → RTSP).
- **One client per session id.** A second viewer with the same `uid` gets the first one `UID_BANNED`.
- **The bridge's Kinesis player is broken for cameras that answer `sendrecv`**: offer with
  `addTransceiver(kind, {direction: "sendrecv"})`, not `recvonly` ("Incompatible send direction").
- `get_cam_webrtc` in the bridge uses `webrtc.api.wyze.com/signaling/device/<mac>`; the web app uses
  `get-streams` with `provider: "webrtc"`, which also returns `iot-device::iot-state/iot-power`.

## 6. Suggested bridge integration

1. In the camera list, read `p2p.providers`; for `lake` cameras skip TUTK entirely.
2. Add `GET /signaling/<cam>?lake` returning the decrypted Agora session (sections 2–3), renewed hourly.
3. Ship a `lake.html` player (section 4). Document the H.265 caveat for OBS users.

## 7. Reproduce it, step by step

Everything below is in this repo. Tested on macOS (Apple silicon) with Docker via Colima, but the only
Mac-specific parts are `launchd` and the Chrome path; Linux users can run the same commands under systemd.

**What you need**
- A Wyze account with an **API key pair** (https://developer-api-console.wyze.com/), the same thing
  docker-wyze-bridge needs.
- Docker (`brew install colima docker docker-compose && colima start` on a Mac).
- Google Chrome **130 or newer** (H.265 in WebRTC). Safari and OBS's built-in browser will not decode the V4.
- `mediamtx` (`brew install mediamtx`) if you want the stream as RTSP for OBS/ffmpeg/Home Assistant.
- ffmpeg, optional, for stills and tests.

**A. Bridge + provisioner (Docker)**
1. `bridge/setup-wyze.sh` writes your Wyze login and key pair into `.env` (nothing is echoed).
2. `docker compose -f bridge/docker-compose.yml up -d`. Two containers start: `wyze-bridge` (web UI on
   http://localhost:5050) and `lake-provisioner`, a sidecar that runs `lake/provision.py` inside the
   bridge image, reusing the bridge's saved login from the shared `tokens/` folder.
3. `bridge/discover.sh` prints camera names and models. The V4 shows as `HL_PAN4`; the bridge itself will
   keep logging `IOTC_ER_UNLICENSE` for it, which is expected and harmless.
4. The provisioner writes `overlay/lake/<camera-name>.json` for every camera Wyze marks as `lake`
   (set `LAKE_CAMS` in the compose file to limit it). Check: `docker compose logs lake-provisioner` should show
   `provisioned <cam>` and `cat overlay/lake/<cam>.json` should contain `app_id`, `channel`, `rtc_token`.
   It also answers `POST http://localhost:5051/provision/<cam>` for a fresh session on demand; the player
   uses that on every start because a *fresh* `create-connection` is what makes the camera join the channel.

**B. The Agora SDK**
`players/get-agora-sdk.sh` downloads Agora Web SDK NG 4.24.0 (the version Wyze's viewer bundles) into
`overlay/agora-rtc-sdk.js`; the bridge serves the whole `overlay/` folder at
`http://localhost:5050/static/snakecam/`. Agora's CDN is not reachable from OBS's browser, so it is served locally.

**C. See the picture (5-minute test)**
Open in Chrome: `http://localhost:5050/static/snakecam/lake.html?cam=<camera-name>&res=HD&codec=h265`.
The status line at the bottom walks through `joining`, `waking camera`, `user-published`, `playing`.
First video takes 5–15 s. `res` is `360p | SD | HD | 2k` (2k arrives as 3840x2160 on the V4).
Close this tab before running the headless decoder below: one client per session id, or the first gets `UID_BANNED`.

**D. Decode once, republish locally (for OBS, ffmpeg, Home Assistant…)**
The V4 only sends H.265 and most consumers can't take it straight from Agora, so a headless Chrome decodes
it and republishes H.264 into a local mediamtx over WHIP; everything else pulls RTSP.
1. `relay/mediamtx.yml`: WHIP in on :8890, RTSP out on :8555, no auth (loopback only). Run
   `mediamtx relay/mediamtx.yml` (or install `launchd/com.snakecam.relay.plist`).
2. Headless Chrome, exactly as in `launchd/com.snakecam.coolcam.plist`:

       "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new \
         --user-data-dir="$HOME/Library/Application Support/snakecam-coolcam" --no-first-run \
         --autoplay-policy=no-user-gesture-required --disable-background-timer-throttling \
         --disable-renderer-backgrounding --window-size=1920,1080 --remote-debugging-port=9224 \
         "http://localhost:5050/static/snakecam/lake.html?cam=<camera-name>&res=2k&codec=h265&whip=http://localhost:8890/coolcam/whip"

   `&whip=` switches the page into relay mode: it captures the decoded `<video>`, scales 4K to 1080p, and
   publishes it (`maintain-resolution`, 6 Mbps). `--remote-debugging-port` is optional; it lets you inspect
   the page (`http://localhost:9224/json`) and is what our self-check scripts use.
3. Verify: `ffmpeg -rtsp_transport tcp -i rtsp://127.0.0.1:8555/coolcam -frames:v 1 test.jpg`, or open the
   RTSP URL in VLC. mediamtx logs `is publishing to path 'coolcam'` when the page is in.
4. OBS: add a **Media Source**, input `rtsp://127.0.0.1:8555/coolcam`, untick "local file", tick
   "restart when inactive". `obs/SnakeCam.json` is our scene file. The Pan V3 (hot side) uses the same
   relay trick but from Kinesis WebRTC (`players/cam.html`, `launchd/com.snakecam.hotcam.plist`).
5. `scripts/install-launchd.sh` installs relay + both decoders (+ OBS, watchdog) as launchd agents so
   the Mac brings everything up on its own after a reboot.

**E. Keeping it alive**
- The player re-requests the resolution every 4 s until the picture arrives at size, then stops.
- If the connection stays "connected" but frames stop for three checks in a row, the page reboots the
  camera through the bridge (`GET http://localhost:5050/api/<cam>/power/restart`, a cloud call that works
  even though TUTK doesn't), waits 90 s and reconnects; at most once per 15 min.
- The provisioner renews the RTC token every 45 min (`RENEW_EVERY`), and the page asks for a fresh session on
  every reconnect.

## 7b. Pan/tilt over the lake channel (Pan V4) — found 2026-09-03

The Agora data stream that carries `set_property camera::resolution` also carries pan/tilt. The camera acknowledges every
command (`*_ack` with `result`: 1 = done, 2 = unknown), which is how the names were found: sending guesses and reading the acks.

    client.sendStreamMessage(new TextEncoder().encode(JSON.stringify(
      [{"cmd":"run_action","action":"camera-position::move-position","params":{"direction":"left","speed":5,"step":10}}])))
    // ack: {"cmd":"run_action_ack","action":"camera-position::move-position","result":1,"ts":...}
    // direction: left | right | up | down   step: 1–60 (10 = a small nudge, 20 clearly visible)   speed: 5 works
    // also seen: "camera-position::stop-move-position"

Verified by measuring the picture: left 20 then right 20 returns to the starting frame (difference 0.7 vs a noise floor of 0.3).
Params like `{"direction":"left"}` alone, `{"horizontal":..}`, `{"pan":..}` are refused (result 2); `direction` + `speed` + `step` are all required.
`get_property` on `camera-position::*` names returns nothing, so position readback is not available; keep your own step ledger to go "home".
The **Pan V3** (Kinesis path) does **not** accept any of this on its data channel ("Json interface not supported" for every interface
name tried); its pan/tilt remains TUTK-only (the bridge's `rotary_*` commands) or the Wyze app.

In this kit: `chatbot/cleobot.py` `cam_move()` / `cam_home()` (via the decoder page's debug port), chat commands `cam left|right|up|down [step]`,
`cam home`, `cam find` (a vision call says where the snake is; the camera nudges toward her), and an automatic find-and-nudge when the sensor hub reports motion.



| Symptom | Cause | Fix |
|---|---|---|
| `IOTC_ER_UNLICENSE` in the bridge log for the V4 | The camera has no TUTK service at all | Ignore; use the lake path above. |
| Provisioner logs `no lake cameras` | Wyze doesn't list the camera as `lake` for your account/firmware | Check `p2p.providers` in `get-home-devices` (section 1); older V4 firmware may still be on TUTK trial paths. |
| `join` succeeds, never `user-published` | Camera not woken, or a cached session | The page must send `sight-safe::check-user` with your Wyze `user_id` repeatedly, and the session must come from a fresh `create-connection` (POST :5051/provision/<cam>). |
| `UID_BANNED` | Two clients with the same uid | Close the other tab/decoder; each session id serves one client. |
| Video element stays 0x0 / `RECV_VIDEO_DECODE_FAILED` | Browser can't decode H.265 | Chrome ≥ 130 (`&codec=h265`); OBS's CEF cannot, hence the relay. |
| Picture stuck at 640x360 | Resolution request ignored | The page re-asks every 4 s; add `&res=2k` (or HD). |
| Relay "connected" then drops every 20 s, mediamtx says `no stream on path` | An unscaled 4K frame hit the WHIP encoder | Fixed in `lake.html` (scale computed before the first frame); update the player. |
| `Failed to unprotect RTP packet`, black picture, everything "connected" | Stale media session on the camera | Reboot the camera via the bridge power API; the page now does this itself. |
| Provisioner `401`/`signature` errors | Wyze changed the web app secret/appid | Grab the new constants from Wyze's web bundle (`_app-*.js`, search `signature2`). |
| Works for an hour then dies | Token not renewed | Provisioner must be running; check `docker compose logs lake-provisioner`. |

## 9. Running it 24/7 — what we learned after a day on air

- **Ask for the resolution until it arrives.** A single `set_property camera::resolution` is often ignored;
  re-send every 4 s until `videoHeight` reaches the target (2k arrives as 3840x2160), then stop.
- **Scale before the first frame reaches the relay encoder.** Feeding an unscaled 4K track into the
  WHIP publisher makes the relay connection drop on the first frame and loop forever. Work out
  `scaleResolutionDownBy` from the requested resolution (or the video element) before `addTrack`,
  and re-check every few seconds. `degradationPreference: "maintain-resolution"` + 6 Mbps keeps 1080p.
- **Stale sessions look connected.** ICE stays connected while SRTP unprotect errors pile up and no
  frame decodes. The fix is a camera reboot (the bridge's `/api/<cam>/power/restart` still works, it is
  a cloud call). The players now do it themselves after three stalled checks, at most once per 15 min.
- **One Agora client per session id.** Opening the player twice bans the first (`UID_BANNED`).
- **PTZ does not ride this path** (or the bridge's TUTK channel inside a NAT'd Docker VM); the Wyze app
  still owns pan/tilt and cruise points. Pause the stream for a few minutes to change them.
- The whole chain is cloud-dependent: camera -> Wyze/Agora -> your machine. A Wyze password or API-key
  change, or a web-app rewrite, can break it. The constants in section 2 come from the web bundle.

## 10. Notes on legality and fragility

- This uses your own account, your own cameras and the same calls Wyze's web viewer makes; nothing is
  bypassed. The `appid`/secret constants are public in Wyze's shipped JavaScript. They can change without notice.
- The Agora Web SDK is Agora's; the download script fetches it from their npm package, it is not redistributed here.
- The Kinesis path for older cameras (`players/cam.html`) is the bridge's `/signaling/<cam>?kvs` endpoint with a
  player that offers `sendrecv`, which the stock bridge player gets wrong.
- If you improve on this (a proper bridge integration, Linux units, a Home Assistant add-on), please open an issue
  or PR so the next Pan V4 owner finds one place with everything.
