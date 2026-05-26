[![Import](https://cdn.infobeamer.com/s/img/import.png)](https://info-beamer.com/use?url=https://github.com/info-beamer/package-instore-radio)

# An In-Store Radio Player for the Raspberry Pi

This package allows you to turn your info-beamer powered
Raspberry Pi into an In-Store Radio Player. Stream audio
content from a streaming source and add local fallback
files. Schedule overlay playback for ads, notifications
or other regular content on top.

While this package supports HDMI output, using a 
[HiFiBerry hat](https://www.hifiberry.com/dacs) for
the Raspberry Pi is highly recommended for perfect
audio quality. 

## Supported HiFiBerry DAC include

 * [DAC+ LIGHT](https://www.hifiberry.com/shop/boards/hifiberry-dac-light/)
 * [DAC+ STANDARD](https://www.hifiberry.com/shop/boards/hifiberry-dacplus-rca-version/)
 * [DAC+ PRO](https://www.hifiberry.com/shop/boards/hifiberry-dac-pro/)
 * While you're checking out their site: [A nice case](https://www.hifiberry.com/shop/#cases) like the one in the picture above.

## Supported features

 * Play an audio stream non-stop
 * Optional local fallback files in case of internet problems
 * Automatically detect silence in stream and trigger fallback
 * Overlay additional audio files at scheduled intervals

## Setting up the info-beamer device

* Assemble the HiFiBerry by attaching it to your Raspberry Pi. Follow the instructions included with the hardware for that.
* Install info-beamer on your Raspberry Pi by following the [device installation instructions](https://info-beamer.com/doc/installing-hosted).
* Connect the device to your [info-beamer account](https://info-beamer.com/auth/signup).
* Import this package by clicking the "Import package" button.
* Create a new setup based on this package by clicking the "Create setup" button.
* Assign this setup to your Pi.

## Selecting a playback method

This currently requires manual configuration adjustments. Shutdown your Pi, take the SD card and make the following changes:

* HiFiBerry output (recommended)
  * Add line `dtoverlay=hifiberry-dacplus` or `dtoverlay=hifiberry-dac` to `/config/userconfig.txt`
  * Set content of file `/config/alsa` to `hifiberry`
* Pi analog output
  * Add `hdmi_ignore_edid_audio=1` to `/config/userconfig.txt` to force analog output
  * Set content of file `/config/alsa` to `rpi`
* Pi HDMI output
  * Add `hdmi_force_edid_audio=1` to `/config/userconfig.txt` to force HDMI output
  * Set content of file `/config/alsa` to `rpi`

## Playback configuration

### Stream settings

* Stream source: Specify an http/https stream of MP3 or AAC content. You can also point to M3U playlists. Consult with
[support](https://info-beamer.com/contact) if you already have a stream producer and need help with integration.
* Stream buffer: Allows you to specify how many seconds of buffer will be filled before playback starts. A longer buffer
might take a while to fill but better helps with brief network outages.

## Local fallback playlist

If the configured stream is interrupted and the buffer runs empty, a local fallback playlist can take over playback
until network streaming is resumed. Additionally this package includes a silence detector: If the stream is working
but sends a mostly silent stream, the fallback can be triggered as well.

* Silence detector threshold: Allows you to specify after how many seconds of silence within the network stream the
fallback is activated. Be sure to set this value high enough so it doesn't get triggered during expected audio pauses.
If you know your content can contain longer pauses, use a higher trigger threshold.
* Fallback switching: Allows you to specify how long the fallback will be active before considering to switch back
to the stream. It might be beneficial to use a high value here to avoid flapping between stream and local content
during internet outages where the internet connection flaps as well.
* Playlist: Specify any number of local fallback audio files. They will be played in the given order. The position
within the fallback playlist is saved. If the player switches between the stream and local playlist, the local
playback resumes where it previously stopped.

## Overlay settings

Overlays allow you to play locally cached audio snippets on top of the normal stream/local playback. This can
be used for regular announcements or other repeating content that is not part of the stream itself.

Each overlay items can be configured individually. The following options are available:

* Start and end hour. This allows you to specify the hours the item will be scheduled.
* The interval and minute setting allow you to specify when this item will be scheduled within the given hour constraint.
If you specify "Between 08:00 and 19:59 at xx:30", the overlay will be triggered on 08:30, 09:30 and so on until 19:30.
* The volume option allows you to control how the normal stream/local playback will be tuned down during overlay playback.
* The combination option allows to to specify how the individual overlay will be scheduled in case other overlays occupy the
same slot. If you have multiple overlays playing at xx:30, each will be triggered in the order within the overlay
configuration. The combination option allows you to specify how they will each behave in regards to all other overlays
triggered.

## General settings

* Timezone: Allows you to specify the timezone used for scheduling overlays
* Base volume: Sets the base output volume. Usually it's recommended to keep the volume at 100% and use the hardware
volume control settings of your playback system to adjust the volume. If that's not possible, you can lower the volume
with this setting.

## Monthly fallback file automation

You can automatically roll out one shared fallback MP3 to all setups using this package.
The process is:

1. Download the newest fallback file from your producer server via `scp`.
2. Upload it as an info-beamer asset.
3. Update all package setups so the local fallback playlist contains exactly this one file.
4. New file replaces old file in all setups.

### 1) Configure environment

Create your env file:

```bash
cp tools/fallback_sync.env.example tools/fallback_sync.env
```

Edit `tools/fallback_sync.env` and set:

* `IB_API_KEY`
* `IB_PACKAGE_ID`
* `SRC_SSH_KEY`
* `SRC_SSH_USER`
* `SRC_SSH_HOST`
* `SRC_REMOTE_DIR`
* `SRC_REMOTE_PATTERN` (for example `*_NewYorker_fallback_INTohneSpot_short.mp3`)

### 2) Test in dry-run mode

```bash
python3 tools/monthly_fallback_sync.py --dry-run
```

### 3) Run live update

```bash
python3 tools/monthly_fallback_sync.py
```

### 4) Schedule monthly (fixed calendar day)

Example: run on day 1 every month at 03:00 (local server timezone):

```cron
0 3 1 * * cd /Users/pknapp/Dev/ib_instoreradio && /usr/bin/python3 tools/monthly_fallback_sync.py >> /Users/pknapp/Dev/ib_instoreradio/tools/fallback_sync.log 2>&1
```

If your automation host is not in Europe/Berlin, set `CRON_TZ=Europe/Berlin` in crontab before this entry.

# Changelog

## Version beta1

Initial public release
