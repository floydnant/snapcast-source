# snapcast-source

Streams macOS system audio straight into Snapcast, bypassing AirPlay.

Replaces a shairport-sync/AirPlay feed into snapserver, which added multi-second and
sometimes wildly variable latency (observed up to ~8s) on top of Snapcast's own buffer.
This path is a fixed ~300-450ms instead, and does not renegotiate mid-stream.

```
macOS app -> BlackHole (virtual output) -> snapcap -> TCP -> snapserver tcp:// source -> clients
```

## Build and run

```sh
cp .env.example .env   # then set SERVER to your snapserver host
make build
make stream
```

`SERVER`, `PORT` and `DEVICE` come from `.env`, which is gitignored so no host or IP
is committed. Anything on the command line overrides it:

```sh
make stream SERVER=192.168.1.50 DEVICE="BlackHole 2ch"
```

Or by hand, without make:

```sh
snapcap "BlackHole 16ch" | nc your-snapserver 4953
```

`make devices` lists device names in the exact form `snapcap` expects. Set BlackHole as
the system output device so apps play into it.

## Server side

`snapserver.conf` needs a `tcp://` source — see `snapserver.conf.example`. It must be an
additional `source =` line **inside the existing `[stream]` section**, not a second
`[stream]` block: `buffer`, `chunk_ms` and `codec` are section-scoped, so a second section
header can override them for the streams already defined.

`sampleformat` must match what snapcap prints on startup. snapcap uses the device's own
rate and does not resample, so if you change BlackHole's rate in Audio MIDI Setup, change
it here too.

Restart to pick up config changes (this briefly drops all connected clients):

```sh
sudo docker restart snapserver
```

## Latency tuning

`buffer` in `snapserver.conf` dominates, and defaults to **1000ms**. 400 is comfortable on
wired or decent WiFi; 250-300 works if clients are wired. It is a **global** setting, so
lowering it also changes any AirPlay stream you kept alongside this one.

`codec = pcm` adds no codec latency at ~1.5 Mbit/s per stream. `flac` roughly halves the
bandwidth for ~26ms.

## Why not ffmpeg

The obvious version of this is one ffmpeg command, and it does not work:

```sh
# Broken: drops ~15% of samples, sounds like constant breakup.
ffmpeg -f avfoundation -i ":BlackHole 16ch" -ar 48000 -ac 2 -f s16le tcp://...
```

ffmpeg's avfoundation input delivers 512-frame buffers at a fixed ~80 per second, capping
it at **40,960 frames/s** regardless of `-ar`. 48 kHz needs 93.75 buffers/s and 44.1 kHz
needs 86.1, so every normal rate starves. Measured here over 15s:

| capture path                     | frames/s delivered | loss   |
|----------------------------------|--------------------|--------|
| ffmpeg avfoundation, BlackHole   | 40,945             | -15.4% |
| ffmpeg avfoundation, built-in mic| 39,936             | -17.1% |
| snapcap (CoreAudio HAL)          | 48,000             | none   |

The microphone result rules out BlackHole and the 16-channel width as causes — it is the
avfoundation path itself. `-thread_queue_size` makes no difference. Lowering the rate to
44.1 kHz does not help either, which is worth knowing because it is the intuitive first
guess when this sounds broken.

Over a 40s run snapcap's only shortfall is a fixed ~0.2-0.5s of device-open cost at
startup, which does not accumulate.

## Known trade-offs vs AirPlay

- **No metadata.** A raw PCM stream carries no track titles, so Snapweb shows none. Would
  need a snapserver `controlscript` scraping macOS Now Playing, and Apple has been
  progressively restricting the MediaRemote API those tools rely on.
- **No system volume.** With BlackHole as output, the Mac's volume keys have nothing to
  act on. Use per-client volume in Snapweb.
- **A/V sync.** ~400ms of audio delay is very visible on video. IINA and VLC both have an
  audio-offset control; otherwise keep AirPlay around for video.
- **Microphone permission.** macOS counts capturing from any audio device as microphone
  access, so the terminal running snapcap needs a grant under
  System Settings -> Privacy & Security -> Microphone.
