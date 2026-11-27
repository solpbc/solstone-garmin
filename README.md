# solstone-garmin

The [solstone](https://solstone.app) app for Garmin watches, built to take in
voice sessions you start on your wrist so they go into your journal once
companion support lands in the solstone app on your phone. When your phone is
out of reach, audio stays on your watch until it reconnects.

## Status

Early public open-source release (Connect IQ API level 6.0.3+, SDK 9.3.0).
The watch app builds cleanly with zero warnings across all 23 watches declared
in `manifest.xml` and completed a continuous 2-hour off-charger run on a
Forerunner 970 (`fw 19.23`, 16 kHz mono Ogg Opus with `FILTER_NREC`, 0 reboots,
0 dropped slabs, `5.2%/h` battery) against a validation android receiver.

Connect IQ Store listing, phone companion integration in the solstone app on
your phone, and design passes are in progress.

## How it works

1. Open `solstone` from the watch's apps menu or a button shortcut and start a
   voice session. (Garmin closes watch apps launched from glances or watch-face
   complications after about two minutes, so sessions start only from the apps
   menu or a button shortcut.)
2. Audio is encoded on the watch as 16 kHz mono Ogg Opus with noise reduction
   (`FILTER_NREC`, when supported) in 5-minute segments, stored on the watch in
   `Application.Storage`, and moves over Bluetooth through Garmin Connect in
   strict half-duplex bursts.
3. When your phone is away, over half an hour of voice audio fits on the watch;
   the session stops when storage fills without overwriting audio that has not
   reached your phone yet. Once your phone reconnects, waiting audio moves
   oldest first and continues in the background after you close the watch app.

## Privacy

- Audio stays on your watch until it moves over Bluetooth through Garmin Connect
  on your phone. Once phone companion integration is ready, it moves from Garmin
  Connect to the solstone app on your phone, and from there into your journal on
  a device you own.
- The watch holds no journal credentials and makes no direct connection to any
  sol pbc server or to the internet.
- The app declares only the three Connect IQ permissions it uses:
  `AudioInput`, `Background`, and `Communications`. It declares no location,
  sensor, or fitness-activity permissions, creates no Garmin FIT activities,
  and includes no analytics, tracking, or crash-reporting SDKs.

## Supported watches

The 23 Connect IQ 6.0.3+ watches with a built-in microphone declared in
`manifest.xml`:

- Approach S72 (43mm, 47mm)
- D2 Mach 2, D2 Mach 2 Pro
- fēnix 8 (43mm, 47mm/51mm, Pro, Solar 47mm, Solar 51mm)
- fēnix 9 (43mm, 47mm/51mm, Pro 43mm/47mm/51mm, Pro Solar 47mm/51mm)
- Forerunner 570 (42mm, 47mm), Forerunner 970
- MARQ (Gen 3)
- Venu 4 (41mm, 45mm), Venu X1

## Layout

```text
manifest.xml            app identity, 23 microphone watches, 3 permissions
monkey.jungle           Connect IQ build configuration
source/
  VoiceApp.mc           minimal AppBase shell (keeps 64 KB background VM lean)
  VoiceBgService.mc     isolated 64 KB background ServiceDelegate burst drainer
  VoiceCaptureEngine.mc ISR-minimal audio callbacks and 5-minute segment loop
  VoiceController.mc    foreground master timer, session lifecycle, display gating
  VoiceProtocol.mc      SLV3/SLVS binary framing, tag16, SPSC metadata keys
  VoiceStorageRing.mc   single-writer integer-keyed ring with empty-window compaction
  VoiceTransport.mc     strict half-duplex burst-and-ACK Bluetooth transport
  VoiceView.mc          AMOLED/MIP/2-button status UI and double-BACK exit guard
  VoiceUnitTests.mc     Connect IQ Run No Evil unit test suite (--unit-test only)
resources*/             app name ("solstone") and resolution-matched launcher SVGs
docs/protocol.md        SLV3/SLVS binary wire format and half-duplex flow
scripts/                formatting/SPDX/permission checks and simulator test runner
```

## Build & test

Requires Garmin Connect IQ SDK 9.3.0+ (`monkeyc`, `monkeydo`, `simulator`) with
device profiles installed for the targets in `manifest.xml`.

```bash
make install     # verify Connect IQ toolchain
make build       # release .prg for fr970 (override with DEVICE=fenix847mm)
make build-all   # strict zero-warning release builds across all 23 watches
make test        # simulator unit tests across AMOLED, MIP Solar, 2-button, and rect targets
make ci          # format-check + build-all + test
make package DEV_KEY=/path/to/developer_key.der  # signed .iq store bundle
```

`make build`, `make build-all`, `make test`, and `make ci` generate an
ephemeral local RSA-4096 signing key under `bin/` automatically when `DEV_KEY`
is not set. `make package` requires an explicit `DEV_KEY`.

See [AGENTS.md](AGENTS.md) for architecture invariants and Connect IQ runtime
constraints, and [docs/protocol.md](docs/protocol.md) for the `SLV3` wire
specification.

## License

AGPL-3.0-only. See [LICENSE](LICENSE).
