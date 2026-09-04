# Rip Night runbook

Cleo watches the glass, names each card, judges it out loud, quotes what it's worth, shows it on screen, and clips it.
Everything below is what happens, what to do, and what can go wrong.

## Commands (channel account only)
| Type in chat | What happens |
|---|---|
| `ripset` | Resets RIP votes, flips the category to **Pokémon Trading Card Game** for 2 h, starts **30 min of watching**. She announces it, spoken. |
| `ripset` again | Adds another 30 min (any time, even mid-session). |
| `pull <name> [<number>]` | You name the card ("pull Umbreon VMAX 215/203"): she prices and judges it now, on screen, spoken, clipped. Use it when she misreads or misses one. |
| `ripstop` / `ripdone` | Ends the session now, reverts the category to the normal block. |
| (nothing) | After **10 quiet minutes** (no hands, cards, packs at the glass) she only glances every 30 s; after **40 quiet minutes** she ends the session herself. |

Viewers can say `RIP` to vote/hype at any time; that is separate from watching.

## The scenarios, in order, and what you should see
1. **Sealed product held to the cool-side glass** (box, ETB, tin, blister, pack): once per product she names it, gives set facts (release date, card count), the sealed market price, one or two chase cards (from the model's own memory: she says "the ledgers are hazy" when unsure), and orders you to open it. On screen: **THE QUEEN INSPECTS · ETB** with the crop and price.
2. **Pack visible**: "The pack is at my glass…" (once per 5 min).
3. **Card held flat, 2–3 s**: she reads the name and collector number, looks the price up in her local price book (instant), then speaks a 1–2 sentence verdict: name, art, shine, "the ledgers whisper… $X". On screen: **PULL n · THE QUEEN JUDGES**, the card cropped from the still, value line, holo shimmer + "HOLO · SLOW BLINK" for foils. A Twitch clip is cut 20 s later.
4. **Dud card**: same flow, a regal dismissal ("worth pennies" is allowed).
5. **Same card again** (a second copy, >45 s later): one short line, "Another X. The ledgers do not blink twice." No second full verdict.
6. **Unreadable card** (angle, glare, too far, motion blur): she stays silent rather than guess. Re-present it flat and still.
7. **Name read slightly differently on consecutive looks** ("Charizard ex" / "Charizard EX"): treated as the same card.
8. **A viewer asks something mid-rip**: their reply goes first; the next look waits a couple of seconds.
9. **Idle**: nothing at the glass → glance every 30 s → session ends after 40 min with a line inviting the next `ripset`.

## What is deliberately different during a rip
- No idle chatter, no camera looks of her own, no games, no court notices, no interludes.
- Her looks and verdicts do **not** count against the chat budget, so a long rip cannot silence her.
- Clips get a bigger allowance (up to 4× the hourly cap, +40 for the day).
- Voice lines are queued: verdicts never talk over each other.
- Price talk is allowed **only** here. Elsewhere she still refuses to talk value, and "nothing for sale" always stands.

## Prices
`chatbot/prices.json` is built by `scripts/build-prices.py` from tcgcsv.com, a free daily dump of **TCGplayer market prices** for every
Pokémon set (≈30k products, sealed included). The bot rebuilds it in the background when it is older than 24 h. Lookup order:
exact **name + collector number** (e.g. `Umbreon VMAX 215/203` → the $2,380 alt art, not the $29 base) → name only (a range, with the
chase printing named) → the pokemontcg.io API as a last resort. Numbers matter: encourage a clear read of the bottom-left number.
We do **not** scrape eBay/TCGplayer pages: both serve automated browsers a bot-check page, and we don't work around that.

## Physical setup that makes it work
- Use the **cool-side camera** (the 4K one; the still she reads is 1080p). The hot side is 360p and cannot read text.
- Card **flat against the glass**, centred, held still for 2–3 s. Foils: tilt slightly so the shine is visible, then flat.
- Light from the front, not behind the card. Avoid the IR night mode if you can (rip while the room is lit).
- One card at a time. A fanned hand of cards reads as "no card".

## Tuning knobs (.env)
`CLEOBOT_RIP_WATCH_MINUTES` (30) · `CLEOBOT_RIP_WATCH_EVERY` (6 s) · `CLEOBOT_CLIPS_PER_HOUR` (6, ×4 during a rip) ·
`CLEOBOT_VOICE_ON` (1) · `CLEOBOT_PIPER_VOICE` (en_GB-alba-medium) · `CLEOBOT_VISION=0` disables all camera looks.

## Known limits
- Name/number reads through glass will sometimes be wrong; a wrong number gives a wrong exact price. Correct her with `pull <name> <number>` from the channel account.
- The vision call is 5–10 s per look; with 6 s spacing she comments 10–15 s after you hold a card up.
- Chase-card lore is model memory, not the price book.
- The price book is TCGplayer market, not eBay sold comps; graded cards are not in it.

## The joint test plan
`ripset` → hold up the sealed product → open → 6–8 cards including one foil, one dud, one duplicate, one at a bad angle → a viewer question
mid-rip → `ripset` (extend) → `ripstop`. Watch: read accuracy, timing, verdict length, voice pacing, clip count on the Clips tab.
