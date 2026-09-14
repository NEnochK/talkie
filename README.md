# Talkie

Two iPhones, two sets of AirPods, one conversation — over Bluetooth LE, with no
cellular, no Wi-Fi network, no server and no account. Works in airplane mode with
Bluetooth on.

Push-to-talk or open-mic with a mute toggle, on named channels so several pairs
can use the app in the same room without colliding.

## Layout

```
TalkieCore/          Swift package. Platform-agnostic, unit-tested on macOS.
  Sources/COpusShim/   Non-variadic C wrappers around libopus
  Sources/TalkieCore/  Channel, Packet, ControlMessage, PCMRingBuffer,
                       JitterBuffer, OpusCodec
  Tests/               50 tests, `swift test`
Talkie/              iOS app target
  Audio/               AVAudioSession config, capture + playback graph
  Transport/           Transport protocol, BLE central/peripheral roles, loopback
  Session/             CallSession state machine, link stats, channel store
  UI/                  SwiftUI, Theme.swift holds the palette
  Assets.xcassets/     App icon (generated, see Tools/)
```

## How it works

Capture at 16 kHz mono → Opus (20 ms frames, 20 kbps, in-band FEC, DTX) → a
4-byte-header packet → BLE GATT → jitter buffer → decode pump → lock-free ring →
`AVAudioSourceNode`.

Two rules the design exists to satisfy:

- **The render block is realtime.** It never allocates or locks; it drains a
  preallocated single-producer/single-consumer ring. Decoding happens off-thread.
- **Stale audio is worthless.** Every queue drops rather than buffers under
  backpressure, and counts the drop.

### Why these choices

**Bluetooth LE, not Multipeer Connectivity.** Apple's docs still claim MPC uses
"Bluetooth personal area networks", but that has been false for about a decade —
MPC is peer-to-peer Wi-Fi (AWDL) only, and does not connect with Wi-Fi off. Core
Bluetooth is the only real iPhone-to-iPhone Bluetooth path.

**16 kHz is a ceiling, not a choice.** Using the AirPods microphone forces the link
from A2DP to HFP, and the AirPods input device is natively 16 kHz mono. iOS 26's
`.bluetoothHighQualityRecording` avoids that downgrade but the SDK documents it as
compatible only with `AVAudioSessionMode.default` and "not recommended for
real-time communication usage". We need `.voiceChat` for echo cancellation and
AGC, so it is deliberately unused.

**No PushToTalk framework.** `PTChannelManager` looks purpose-built for this, but
it signals transmissions through APNs and therefore needs a server and a network —
exactly what this app is avoiding. Plain `UIBackgroundModes: audio` keeps the
process alive instead.

**Budget.** ~22 kbps against 200+ kbps available, so roughly 5-10% of the link.
Latency is ~130 ms app-level, ~250-350 ms mouth-to-ear once AirPods HFP is counted
at both ends. Most of that tail is AirPods and outside our control.

## Notes where the implementation departs from the original plan

1. **Role negotiation moved after connection.** The plan put a random tiebreak
   nonce in BLE manufacturer data. That breaks exactly when it matters: iOS strips
   manufacturer data *and* the local name once the app is backgrounded, leaving
   only the service UUID. Instead both devices advertise and scan, either may
   connect, and each sends a persistent per-install identity in its `hello` over
   the control characteristic; the higher identity drops its own outbound
   connection. Both sides compute the same answer and it works in every app state.
2. **A C shim target was required.** `opus_encoder_ctl` is a C variadic and Swift
   cannot call those, so `COpusShim` exposes the needed operations as ordinary
   functions.
3. **An `ogg` dependency came along for the ride.** The prebuilt `opus.framework`
   bundles opusfile and libopusenc, so its binary hard-links `@rpath/ogg.framework`
   and will not load without it. The shim also compiles with `-fno-modules`,
   because the framework's module map declares an `opusfile` submodule that
   includes `<ogg/ogg.h>`.
4. **Info.plist is generated from build settings** (`INFOPLIST_KEY_*`) rather than
   checked in, so there is one less file to keep in sync.
5. **Added a playback backlog guard.** The decode pump is a dispatch timer while
   the speaker runs off the audio clock, so the two drift. The pump refuses to
   enqueue past three buffered frames, which stops drift becoming creeping latency.
6. **`UIBackgroundModes` lives in `Config/Info.plist`, not a build setting.**
   `INFOPLIST_KEY_UIBackgroundModes` is not a recognised setting name — Xcode
   ignores it silently and the key never reaches the built app, which costs
   background audio and BLE the moment the screen locks. There is no build-setting
   equivalent for it or for `CFBundleURLTypes`, so both live in a small plist that
   Xcode merges the generated keys into. Worth re-checking with
   `PlistBuddy -c "Print :UIBackgroundModes" <built .app>/Info.plist` after any
   project change.
7. **Swift language mode 5**, not 6. The Core Bluetooth delegate surface is
   callback-heavy; `CallSession` instead serialises everything onto one queue and
   documents that invariant.

## Channels

A channel is just a name. Everyone who types the same name lands in the same room;
names are case-, whitespace- and Unicode-normalized, so "My Crew", "my  crew" and a
decomposed-accent spelling all agree.

**The name is hashed into the BLE service UUID** (SHA-256 over a fixed namespace
plus the normalized name, shaped into an RFC 9562 version 8 UUID). That is not a
stylistic choice. iOS strips manufacturer data, service data and the local name the
moment the app backgrounds, leaving only service UUIDs in the advertisement's
overflow area — so a channel ID carried in the payload would work in the foreground
and silently stop working when the screen locked. Encoding it in the UUID is the
only form that survives.

It also makes channels unlisted: `scanForPeripherals` is handed the exact UUID to
match, so a channel you do not know the name of is not discoverable.

Channels are shared by QR code carrying `talkie://join?c=<name>`. The scheme is
registered, so the system Camera app opens one straight into the app — the person
joining does not need to have Talkie open.

Switching channel tears down and re-establishes the link, because the channel *is*
the service UUID; there is nothing to renegotiate on an existing connection.

## App icon

Generated rather than checked in as opaque artwork, so the geometry is reviewable
and the mark can be re-rendered after a tweak:

```sh
swift Tools/GenerateAppIcon.swift
```

The mark is a centre dot with concentric arcs radiating **both** left and right —
a two-way radio rather than a broadcast. No text, symmetric, and still legible at
40 points.

Three appearances ship: the accent-blue default, a dark variant on the same
near-black the UI uses, and a greyscale tinted variant (iOS derives the tint from
luminance, so colour there would simply be discarded). Verify what actually
compiled with `xcrun assetutil --info <built .app>/Assets.car` — it should list
`UIAppearanceDark` and `ISAppearanceTintable` renditions alongside the default.

The bitmap context uses `noneSkipLast`, not `premultipliedLast`: App Store Connect
rejects an app icon carrying an alpha channel, even a fully opaque one. Worth
re-checking with `sips -g hasAlpha` after any change to the generator.

## Appearance

Light and dark are both designed explicitly rather than left to system defaults.
`Talkie/UI/Theme.swift` defines every colour as a semantic token resolved through a
dynamic `UIColor`, so it follows the trait collection — which means one definition
covers both the system setting and the in-app override, with no duplicate plumbing.

Dark is built on a near-black with a slight blue cast (`#0B0D10`) rather than pure
black: lifted card surfaces need something to lift away from, and `#000` leaves
them with nothing to separate against.

The appearance control is the half-circle icon in the top-left — System, Light or
Dark, persisted in `@AppStorage`.

## Inspecting the UI without hardware

DEBUG builds accept two launch arguments that seed a plausible state without
starting a session or touching the radio. Useful before device signing is sorted:

```sh
xcrun simctl launch <device> com.talkie.Talkie -uiDemo           # connected, transmitting
xcrun simctl launch <device> com.talkie.Talkie -uiDemoSearching  # searching, controls inert
xcrun simctl launch <device> com.talkie.Talkie -uiDemoChannel    # opens the channel picker
```

These only seed UI state. The audio path needs a real device — see below.

## Testing audio on one device

The loopback rig runs your own voice through the whole chain — capture, Opus
encode, a fake transport that drops and delays packets, the jitter buffer, decode,
playback — and back out to your AirPods. No second phone, no BLE.

On the device, DEBUG build: **Loopback test → sliders → Start loopback**, or drive
it straight from the command line:

```sh
xcrun devicectl device install app --device <udid> \
  <derived>/Build/Products/Debug-iphoneos/Talkie.app

# note the -- separator; devicectl parses leading-dash args itself otherwise
xcrun devicectl device process launch --device <udid> --terminate-existing \
  com.enoch.Talkie -- -autoLoopback -loss 10 -jitter 40
```

**Burst length is the control that matters.** Measured offline on 10 seconds of
speech:

| condition | result |
|---|---|
| 10% uniform loss | 39 of 55 drops genuinely repaired by FEC; 57 dB SNR vs clean — inaudible |
| 30% uniform loss | 21 dB — mildly audible |
| 120 ms jitter | output **bit-identical** to a clean run — no effect whatsoever |
| 160 ms jitter | first late arrivals appear, at the buffer's max depth |
| 10% loss, burst 6 | only 7 of ~50 repaired, 45 concealed — clearly audible |

Two things follow. Jitter below roughly 160 ms cannot do anything, because that is
the adaptive buffer's ceiling (`JitterBuffer.maxDepth`, 8 frames) — the slider goes
to 400 ms so it can actually exceed it. And uniform loss is largely invisible
because Opus in-band FEC carries a copy of frame N inside frame N+1, so isolated
drops are repaired; raise **Loss burst** past 1 to defeat that, which is also what
radio contention really does.

Watch the Link quality panel while you sweep — it opens expanded during a loopback
run. `concealed` versus `FEC recovered` is the interesting pair.

### Reading the FEC counter

`fecRecovered` counts frames rebuilt from an in-band FEC copy that was **verified
present**, via `opus_packet_has_lbrr`. This matters: `opus_decode` with
`decode_fec=1` returns a full frame whether or not the packet carried a repair
copy, silently substituting concealment. Counting attempts rather than repairs
inflated the figure roughly 4x on synthetic audio, and made the statistic
impossible to regress-test — a build with FEC switched off scored identically.

### Offline harness

The same pipeline runs headless on the Mac, with no device at all:

```sh
say -v Samantha -o /tmp/s.aiff "the quick brown fox jumps over the lazy dog"
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/s.aiff /tmp/s.wav

swift run --package-path TalkieCore talkie-loopback \
  --input /tmp/s.wav --output /tmp/out.wav --loss 10 --burst 6 --jitter 40
afplay /tmp/out.wav
```

It drives the real `OpusEncoder`, `JitterBuffer` and `OpusDecoder` — only the
transport and the clock are simulated, which makes runs deterministic (`--seed`)
and the statistics directly comparable. `--synthetic <seconds>` skips the input
file entirely; `--expected-loss` sets `OPUS_SET_PACKET_LOSS_PERC`, and `0` turns
FEC generation off for an A/B.

The same simulation backs the end-to-end tests in
`Tests/TalkieCoreTests/EndToEndAudioTests.swift`, so what the tests assert and
what the tool prints come from one code path. They cover the clean link,
determinism, loss accounting, the FEC A/B, burst behaviour, and the jitter
absorb/degrade boundary — 85 tests, well under a second, no hardware.

Verified by mutation: disabling in-band FEC, shrinking `JitterBuffer.maxDepth`, or
dropping the LBRR check each fail several of them.

The Simulator is not useful for this. It has no Bluetooth at all, no AirPods route,
and `setVoiceProcessingEnabled` is unreliable there — so echo cancellation and AGC,
the two things `.voiceChat` exists for, are not what ships on device.

Pair with `xcrun simctl ui <device> appearance dark|light` to check both schemes.

## Building

```sh
swift test --package-path TalkieCore          # 50 tests, no hardware needed
xcodebuild -project Talkie.xcodeproj -scheme Talkie \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build
```

Set a development team in the target's signing settings before running on device.

## Verification status

**Done — automated, no hardware:**

- 50 unit tests covering packet framing and sequence wraparound, control-message
  encoding, SPSC ring-buffer ordering under concurrency and underrun zero-fill,
  jitter-buffer reordering / FEC recovery / concealment / late discard / adaptive
  depth / re-priming, and Opus round-trip, DTX and loss paths.
- Both simulator and device (arm64) targets compile clean.

**Not done — needs two iPhones and two sets of AirPods.** Core Bluetooth and
microphone input do not work in the Simulator, so none of the following has been
exercised:

- [ ] Single device: DEBUG build → "Loopback test" → sweep loss 0/5/10/20% and
      jitter 0-120 ms. Confirms the whole audio chain and lets the jitter buffer be
      tuned against reproducible impairment. **Do this first** — it catches most
      audio bugs without a second phone.
- [ ] Discover and connect in under 5 s, foreground.
- [ ] Push-to-talk, verified in both directions.
- [ ] Open mic plus mute toggle; confirm the peer sees the mute state.
- [ ] Lock both screens → audio continues.
- [ ] **Airplane mode with Bluetooth on, both devices → the call still works.**
      This is the test that proves the premise.
- [ ] Walk to the range limit → graceful degradation, then automatic reconnect.
- [ ] Background both apps → confirm overflow-area discovery still connects.
- [ ] Crossed-connection tiebreak: start both apps simultaneously, repeatedly, and
      confirm exactly one link survives each time.
- [ ] Channel isolation: put two devices on "alpha" and a third on "bravo"; the
      third must never be discovered by the first two.
- [ ] Channel switch while connected drops the old link and finds the new room.
- [ ] QR join: show a code on one device, scan with the other, and also scan it
      with the system Camera app to confirm the URL scheme opens the app.
- [ ] Mouth-to-ear latency: play a click on A, record on B with a third device.

The in-app "Link quality" panel reports round trip, loss, buffer depth,
concealments, FEC recoveries, late frames, rebuffers, radio drops and playback
drops — enough to characterise a bad call without a debugger.

### Known risk

Both radios share 2.4 GHz: phone↔AirPods HFP and phone↔phone BLE time-divide
against each other. The low bitrate leaves a lot of headroom and Opus FEC plus the
adaptive jitter buffer should absorb the rest, but this is the thing most likely to
misbehave in the real world. If it does, drop `AudioConfig.bitrate` to 12-16 kbps
first. `BLEConstants.requireEncryption` can be set false to isolate a pairing
problem during bring-up — at the cost of sending voice in the clear.
