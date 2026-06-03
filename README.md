[![Import](https://cdn.infobeamer.com/s/img/import.png)](https://info-beamer.com/use?url=https://github.com/info-beamer/package-instore-radio)

# In-Store Radio Player (info-beamer package)

This package runs an always-on in-store radio player on info-beamer hosted devices.
It supports:

- primary internet stream playback (MP3/AAC URL)
- local fallback playlist when stream fails or is silent
- scheduled ad blocks (time-based local audio playback)
- Start/Stop controls in setup UI
- playback event extraction from device logs

This README documents the current project state as of **June 3, 2026**.

## Current Status

- Stream playback is stable in normal online operation.
- Fallback activation/deactivation logic has been hardened against flapping.
- Debug screen now shows stream/fallback/ad-block/silence sections reliably.
- Monthly fallback file rollout automation script exists in `tools/`.
- Ongoing: long-run offline/online soak test.

## Repository Layout

- `node.lua`: main runtime (stream player, fallback, ad blocks, silence detector, debug render).
- `node.json`: setup schema shown in info-beamer hosted.
- `control.html`: Start/Stop controls shown in setup UI.
- `service`: python2 service process (time mapping + playback event harvesting from `logread`).
- `tools/extract_playback_log.py`: parses exported device log, summarizes playback/fallback/ad-block behavior.
- `tools/monthly_fallback_sync.py`: monthly automation to replace fallback playlist asset in all setups of this package.
- `tools/fallback_sync.env.example`: env template for monthly sync.
- `idle.mp3`: built-in emergency local file if playlist is empty/unavailable.

## Runtime Architecture

Main modules in `node.lua`:

- `StreamPlayer(url, buffer)`
- `Fallback()`
- `AdBlockScheduler()`
- `SilenceDetector()`

Render loop (`node.render`) performs:

1. update schedule clock (local fallback when `/time` mapping is absent)
2. evaluate fallback necessity
3. pick active source (stream, fallback, ad block, stopped)
4. tick players and detectors
5. apply mixing/ducking rules
6. draw debug output

## Playback Logic

### Stream

- `resource.load_audio` is used with configured URL and buffer.
- Stream is considered healthy after successful start.
- Startup grace window is applied on opening/reopening to avoid false fallback triggers.

### Fallback

Fallback is activated when stream is broken or silent long enough.
Important guards:

- confirmation window (`unstable_confirm_seconds`) to avoid short jitter triggers
- minimum active fallback time (`min_fallback`)
- startup grace suppression only during initial startup scenarios
- runtime stall detection (`runtime_broken`) when stream sits in paused/loaded without progress
- while fallback is active and stream stays broken, fallback window is extended

If playlist is empty, fallback now safely defaults to `idle.mp3` (no modulo-by-zero crash).

### Ad Blocks

Configured ad blocks can trigger on fixed minutes or repeating intervals:

- mode `single`: rotate one item per slot
- mode `all`: play all block files in sequence per slot
- stream/fallback is ducked using configured `duck_volume` during ad playback

## Debug Screen Interpretation

The color/source state:

- green: stream
- red: fallback
- yellow: ad block
- blue: manual stopped state

Key sections:

- `NOW PLAYING` source
- `Stream`: URL, state, buffer, metadata
- `Fallback`: active remaining time or not active
- `Local`: currently loaded fallback file/player state
- `Ad Blocks`: clock + queue size
- `Silence detector`: silent duration, threshold, floor, loudness

If any module throws runtime errors, they are now shown directly in debug text (for example `stream error: ...`) and logged with `[PLAYER] ... error`.

## Setup Configuration (node.json)

Main sections currently used:

- **Stream settings**
  - Stream Source
  - Stream Buffer
- **Local fallback playlist**
  - Silence detector threshold
  - Silence detector sensitivity (`silence_floor`)
  - Minimum fallback duration (`min_fallback`)
  - Playlist resources
- **Ad Blocks (beta)**
  - block name
  - hour range
  - minute schedule
  - duck volume
  - mode (`single` / `all`)
  - block files
- **General settings**
  - timezone
  - base volume

## Control UI

`control.html` provides:

- `Start` -> command `player/start`
- `Stop` -> command `player/stop`

Manual stop forces source `stopped`. Manual start re-enables stream and briefly suppresses fallback checks.

## Logging and Diagnostics

### Playback Events

`node.lua` emits:

- `[PLAYBACK] <event> <json>`
- `[PLAYER] <message>`

`service` tails device logs (`logread -f -e PLAYBACK`) and stores parsed events in memory/file flow.

### Device Log Analysis Tool

Use:

```bash
python3 tools/extract_playback_log.py /path/to/device-debug-log.txt --summary --newest-first --limit 2000
```

Outputs include:

- stability analysis
- fallback trigger metrics
- ad block trigger/start/finish analysis
- per-event timeline

## Known Incidents and Fixes

1. **Audio backend unavailable**
   - root cause was device audio backend/hardware routing, not package logic.
2. **Frequent fallback flapping**
   - tuned with startup grace, confirmation window, and stronger checks.
3. **Debug screen lower half missing**
   - caused by runtime errors in tick/mix path.
   - mitigated with guarded `pcall` blocks and explicit error rendering.
4. **Fallback not active during prolonged offline state**
   - hardened with runtime stall detection and fallback extension while stream remains broken.
5. **Empty fallback playlist crash**
   - fixed by safe fallback to `idle.mp3`.

## Long-Run Test Checklist

For each test run, capture snapshot + device log export.

### Online stability

- stream should remain active (green)
- no repeated fallback activations without trigger reason
- no runtime error lines in debug screen

### Offline behavior

- disconnect internet
- within threshold + confirmation window, fallback should activate
- local file should continue looping
- reconnect internet: stream should recover and become active again after rules permit

### Ad block behavior

- trigger at configured minute/interval
- verify `ad_block_triggered`, `ad_block_item_started`, `ad_block_item_finished` in extracted logs

## Monthly Fallback File Automation

Goal: roll out one shared fallback MP3 to all setups of this package.

Script: `tools/monthly_fallback_sync.py`

Flow:

1. download newest fallback MP3 from producer host via `scp`
2. upload as info-beamer asset
3. list setups using package ID
4. replace each target node playlist with exactly that uploaded file

Configure:

```bash
cp tools/fallback_sync.env.example tools/fallback_sync.env
```

Run test:

```bash
python3 tools/monthly_fallback_sync.py --dry-run
```

Run live:

```bash
python3 tools/monthly_fallback_sync.py
```

Cron example (monthly day 1 at 03:00):

```cron
0 3 1 * * cd /Users/pknapp/Dev/ib_instoreradio && /usr/bin/python3 tools/monthly_fallback_sync.py >> /Users/pknapp/Dev/ib_instoreradio/tools/fallback_sync.log 2>&1
```

If scheduler host timezone differs, set `CRON_TZ=Europe/Berlin`.

## Operational Notes

- On hosted package updates via git push, ensure the setup is saved/applied when config changes are made.
- If VS Code/Cursor Git UI hangs on commit, close `COMMIT_EDITMSG` editor or commit from terminal with `-m`.
- For low-level troubleshooting always trust device debug screen + extracted playback timeline over UI assumptions.
