# snapcast-source

Streams a Mac's system audio into Snapcast. A menu bar app on the Mac and a small relay
on the Snapcast server. No virtual audio driver, no AirPlay, no IP addresses to configure.

```
Mac A: Snapcast Source.app ─┐
                            ├─► snapcast-relay ──► FIFO ──► snapserver pipe:// ──► speakers
Mac B: Snapcast Source.app ─┘   (one TCP port,
                                 found via Bonjour)
```

Replaces an AirPlay/shairport-sync feed, which added multi-second and sometimes wildly
variable latency (observed up to ~8s) on top of Snapcast's own buffer. This path is fixed
at snapserver's `buffer` plus a few tens of milliseconds, and does not renegotiate.

## Setup

**Server** (one time). From the Mac:

```sh
cp .env.example .env        # set SERVER, and SSH_HOST if your ssh alias differs
make deploy-relay
```

This installs `snapcast-relay` as a systemd **user** service: no root needed. It enables
lingering so the relay starts at boot, and advertises itself over mDNS through the
server's existing avahi-daemon.

Then add the relay's source to `snapserver.conf` (see `snapserver.conf.example`) and
restart snapserver:

```sh
sudo docker restart snapserver
```

**Each Mac** (macOS 14.2 or later):

```sh
make install                # builds, signs, copies to ~/Applications, opens it
```

The first time you start streaming, macOS asks for permission to capture system audio.

## Using it

Click the speaker in the menu bar, then **Start Streaming**. The app finds the relay by
itself. What you hear on this Mac moves to your Snapcast speakers; this Mac is muted while
streaming unless you untick **Mute this Mac while streaming**.

**Several Macs.** Any Mac can take over the stream at any time, and the newest one wins.
The Mac that was replaced shows "*Mac B* took over" and stays stopped until you press
**Take Over**. It never grabs the stream back by itself, which would have two Macs
fighting over it forever. While you're not streaming, the menu shows which Mac is.

**Volume.** The slider sets the stream's volume. By default the stream also follows this
Mac's own volume and mute, so the volume keys keep working while local output is muted.
That needs doing explicitly: the tap captures what apps play *before* the output device
applies its volume. Audio interfaces with only a hardware knob have no software volume;
for those, the slider is the only control.

**Speakers.** The menu lists the Snapcast speakers with mute and volume, through
snapserver's own control API (the one Snapweb uses). The relay tells the app where that
is, so there is still nothing to configure.

**Automatic source switching.** The relay moves your Snapcast groups to whichever source
started most recently. Start streaming from a Mac, and the speakers switch to the Mac.
Start AirPlaying from a phone, and they switch to AirPlay. When the newer one stops,
they go back to the other; with neither active, they settle on AirPlay. Groups on any
other stream are left alone, and a change you make by hand in Snapweb is not undone until
something new starts or stops. A Mac that drops out briefly (WiFi, sleep, a relay
restart) has 8 seconds to come back before anything switches. Flags: `-auto-switch`,
`-mac-stream`, `-fallback-stream`, `-switch-grace`.

**It looks after itself.** The app reconnects with backoff if the relay or the network
goes away, tears down on sleep and resumes on wake, and rebuilds capture when you switch
output devices. If capture stops delivering audio (for example while macOS is showing
the permission prompt), it rebuilds the tap once, then stops and says why instead of
retrying forever.

## How it works, and why

**No audio driver.** Since macOS 14.2, a CoreAudio *process tap* can capture the mixdown
of everything the Mac plays, with no driver installed. `CATapMuteBehavior.mutedWhenTapped`
silences the local output while capturing. That was the only reason to route audio into
BlackHole in the first place. The tap and its capture device are private to the app and
die with it, so a crash cannot leave the Mac muted.

The capture device contains **only** the tap. The common recipe also adds the output
device as a clock source, but an audio interface with inputs then puts its own input
channels in the same buffer as the tap: measured with a Scarlett 8i6, `10ch + 2ch`.

The alternatives, and why this project doesn't use them: a DriverKit audio extension
needs an entitlement Apple grants per developer team on request. A HAL plugin (what
BlackHole is) needs an admin installer and a `coreaudiod` restart.

**One fixed format.** Everything is resampled on the Mac to 48000:16:2, whatever the
hardware is doing. A Snapcast stream's `sampleformat` is fixed at config time, while a
tap's format follows the output device: plugging in a 44.1 kHz interface would otherwise
break the stream.

**A relay instead of snapserver's `tcp://` source.** That source accepts one connection,
and cannot tell when its peer has gone. A Mac that sleeps or drops off WiFi mid-stream
leaves it holding a dead socket. Every later connection then queues behind it forever,
until snapserver is restarted: everything looks connected, and nothing plays. The relay
owns connection lifecycle instead:

- Sources send continuous audio, so 3s of silence on the socket means the source is gone.
- The relay pings every second, so the app knows within 3s when the relay is gone.
- Newest connection wins, and the previous source is told who replaced it.
- snapserver reads a FIFO that always exists, so its source never wedges.
- Only whole frames are forwarded. A source that disconnects mid-frame would otherwise
  shift the next source's audio by a byte, which plays as full-scale noise.

The wire protocol is documented at the top of `relay/relay.go`.

## Latency

`buffer` in `snapserver.conf` dominates. It defaults to **1000 ms**: 400 is comfortable on
wired or decent WiFi, and 250–300 works if clients are wired. It is a **global** setting,
so it also changes the AirPlay stream.

## Command-line tools

`snapstream` drives the same pipeline headlessly:

```sh
snapstream tap-test --seconds 5     # capture + convert only: frames/s should be ~48000
snapstream browse                   # relays found over Bonjour
snapstream status                   # which Mac is streaming right now
snapstream stream --no-mute         # stream from the terminal
snapstream speakers                 # speakers, volumes and streams, via snapserver
snapstream speaker-volume ID 40     # set a speaker's volume (--mute / --unmute)
```

`--relay host[:port]` (or `$SNAPSTREAM_RELAY`) skips discovery.

`snapcap` is the original tool. It captures a named CoreAudio device, such as BlackHole,
and writes raw PCM to stdout. The relay still accepts that as a raw stream:

```sh
make stream                         # snapcap "$DEVICE" | nc $SERVER $PORT
```

### Why not ffmpeg

ffmpeg's avfoundation input delivers 512-frame buffers at a fixed ~80/s, capping it at
**40,960 frames/s** whatever `-ar` says. Every normal rate starves:

| capture path                      | frames/s delivered | loss   |
|-----------------------------------|--------------------|--------|
| ffmpeg avfoundation, BlackHole    | 40,945             | -15.4% |
| ffmpeg avfoundation, built-in mic | 39,936             | -17.1% |
| snapcap (CoreAudio HAL)           | 48,000             | none   |

## Security

The relay accepts any source on the LAN. To require a shared secret, set `SNAPSRC_TOKEN`
in the relay's environment (for example with a systemd drop-in) and the same token under
Settings in the app. Setting a token also disables raw mode.

## Development

```sh
make test         # Swift unit tests + relay tests under the race detector
make run          # build the app bundle and launch it
```

The Makefile signs with a Developer ID or Apple Development certificate if one is in your
keychain, and ad-hoc otherwise. macOS ties the audio-capture permission to the signature,
and an ad-hoc signature changes on every build, so it asks again after each rebuild.

## Known limitations

- **No metadata.** Snapweb shows no track titles for this stream.
- **No system volume keys** while muted locally. Use per-client volume in Snapweb.
- **A/V sync.** Audio arrives `buffer` ms late, which is visible on video. IINA and VLC
  have an audio-offset control.
- **Excluding apps isn't exposed yet.** The tap captures everything the Mac plays, alert
  sounds included.
- **Snapserver's control port must accept IPv4.** It does by default. The app tries
  IPv4 first because snapserver listens there, while Bonjour otherwise often resolves the
  relay to IPv6.
