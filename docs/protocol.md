# SLV3 Wire & Storage Protocol

`solstone` transfers voice audio from the watch to the paired phone over
Garmin Connect IQ's `Communications.transmit()` channel using a compact,
strictly half-duplex binary framing protocol (`SLV3`), with 24-byte
local link-status frames (`SLVS`).

## 1. Design Constraints

- **Universal 8 KiB slab quantum:** Normal slabs flush once staged mono 16 kHz
  Ogg Opus payload reaches `>= 8,192 B` (chunk-aligned to ~9.05 KB average)
  plus a 28-byte big-endian header; segment-end (`FLAG_SEG_END`) and shutdown
  or interruption tail slabs (`FLAG_SEG_PARTIAL`) may be shorter. This fits
  inside the 64 KB background `ServiceDelegate` memory budget (accounting for
  2-3x transient serialization overhead) while keeping framing overhead low
  enough to transfer faster than real-time 16 kHz Opus audio.
- **Lock-free single-writer `Application.Storage` ring:**
  - Data slots use integer keys `0..959` (`RING_CAP = 960`, ~8.7 MiB ceiling,
    below Connect IQ's 10 MiB storage limit, holding over half an hour of
    16 kHz Opus audio when away from the phone).
  - Key `-1` (`K_FG_META`, foreground sole writer):
    `[headSeq, fgAckedSeq, fgActive, modeId, segId, segEpoch, hbEpoch]`.
  - Key `-2` (`K_BG_META`, background sole writer):
    `[bgAckedSeq, lastSentSeq, wakeCount, lastWakeEpoch, lastErr]`.
  - Key `-3` (`K_HEALTH`):
    `[batStartPct, segsDone, stWriteMaxMs, writeCount, isStalled, modeId]`.
  - Key `-4` (`K_FACE`, foreground sole writer, updated on state transitions only):
    `[phase, reason, lastEnd, startEpochOrZero]`, read-only by the glance VM.
  - Key `-5` (`K_SESSION_META`, foreground sole writer):
    `[lastEndReason, lastEndEpoch, phoneProtoVer, phoneEverAcked, lastPhoneAckEpoch, tzLat100, tzLon100]`.
  - Effective confirmed acknowledgement across both VMs is
    `max(fgAckedSeq, bgAckedSeq)`.
- **Zero-gap empty-window compaction:** Per-slab `Storage.deleteValue()` leaves
  tombstones that trigger multi-second synchronous compaction pauses on flash.
  Instead, after 120 slabs (~1.05 MB, every ~5 minutes), the watch drains its
  pending burst to `0` and calls `Storage.clearValues()` inside the ~2.5-second
  inter-slab window while audio continues uninterrupted in the 32-slot RAM ring,
  rewriting metadata keys immediately. Undelivered slabs are never cleared or
  overwritten.

## 2. `SLV3` Audio Slab Header (28 Bytes, Big-Endian)

| Offset | Size | Type | Field | Description |
|---|---:|---|---|---|
| `0..3` | 4 | ASCII | `magic` | `"SLV3"` (`0x53 0x4C 0x56 0x33`) |
| `4` | 1 | `uint8` | `protoVer` | Protocol version (`1`) |
| `5` | 1 | `uint8` | `flags` | `b0=SEG_START`, `b1=SEG_END`, `b2=ACK_REQ`, `b3=MORE_PENDING`, `b4=BG_ORIGIN`, `b5=SEG_PARTIAL` |
| `6..7` | 2 | `uint16` | `segId` | Monotonic segment counter persisted across restarts |
| `8..11` | 4 | `uint32` | `seq` | Monotonic global slab sequence (idempotency and oldest-first ordering key) |
| `12..15` | 4 | `uint32` | `segEpoch` | Watch UTC epoch seconds at segment start |
| `16..17` | 2 | `int16` | `tzOffsetMin` | Watch local UTC offset in signed minutes at segment start |
| `18..21` | 4 | `uint32` | `relMs` | Milliseconds elapsed since segment start |
| `22` | 1 | `uint8` | `rateKhz` | Sample rate in kHz (`16` or `8`) |
| `23` | 1 | `uint8` | `reserved` | Reserved (`0`) |
| `24..25` | 2 | `uint16` | `payloadLen` | Exact Ogg Opus payload byte count following byte 27 |
| `26..27` | 2 | `uint16` | `tag16` | 16-bit sampled integrity tag over payload bytes |

### `tag16` Algorithm

Samples up to 16 evenly spaced bytes across `payload[0..payloadLen-1]` in
constant time:

```text
h = len & 0xFFFF
if len > 0:
  samples = min(len, 16)
  for k in 0 .. samples-1:
    idx = 0 if samples == 1 else (k * (len - 1)) / (samples - 1)
    b = payload[idx] & 0xFF
    h = ((h * 33) + b + k) & 0xFFFF
return h
```

Test vector: `fastTag16([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0xAB, 0xCD]) == 13358`.

## 3. Strict Half-Duplex Burst-and-ACK Flow

Connect IQ Bluetooth messaging can freeze if watch and phone transmit
simultaneously. Watch and phone therefore alternate strictly:

1. **Watch turn:** Sends up to `K = 8` slabs (`~64-72 KB`), strictly one
   `Communications.transmit(slab, {}, new Listener(weakRef, gen))` in flight at
   a time. Sets `FLAG_ACK_REQ` on the final slab of the burst and enters
   `TX_WAIT_ACK` without sending further messages.
2. **Phone turn:** Validates `"SLV3"` magic, `protoVer`, and `tag16`, writes
   each slab durably to disk by `seq` before acknowledging, and sends
   **nothing** while `FLAG_ACK_REQ` is clear. Only when `FLAG_ACK_REQ` is set
   does the phone send one cumulative acknowledgement
   (`{"a": lastContiguousSeq, "v": 1}` with an optional `"z": [lat100, lon100]`
   system-timezone reference point for the watch sun arc; zero location APIs).
3. **Background drain (`FLAG_BG_ORIGIN`):** When the foreground app exits with
   waiting slabs, `VoiceBgService` wakes on 5-minute temporal events or phone
   wake messages (`onPhoneAppMessage`), drains up to 24 slabs or 22 seconds
   (~180 KB) via callback chaining (zero timers), stamps `FLAG_BG_ORIGIN` on
   each slab and adds `FLAG_ACK_REQ` (plus `FLAG_MORE_PENDING` if more slabs
   wait) on the final slab of the wake, and calls `Background.exit()`. When
   both `FLAG_BG_ORIGIN` and `FLAG_ACK_REQ` are set, the companion waits 2.5
   seconds for the background VM to exit before sending
   `{"a": lastContiguousSeq, "v": 1}` as the next wake doorbell.

## 4. `SLVS` Local Link-Status Frame (24 Bytes, Big-Endian)

Emitted in foreground on app open, 5-minute segment boundaries, and session
stop inside the same half-duplex channel (strictly local watch-to-phone link
status, zero internet calls):

| Offset | Size | Field |
|---|---:|---|
| `0..3` | 4 | Magic `"SLVS"` (`0x53 0x4C 0x56 0x53`) |
| `4` | 1 | `protoVer` (`uint8`, `1`) |
| `5` | 1 | `batPct` (`0..100`) |
| `6..7` | 2 | `segId` (`uint16`) |
| `8..9` | 2 | `freeKb` (`uint16`, watch free heap in KiB) |
| `10..11` | 2 | `stWriteMaxMs` (`uint16`, max `Storage.setValue` duration in ms) |
| `12..13` | 2 | `droppedChunks` (`uint16`) |
| `14..15` | 2 | `bgWakeCount` (`uint16`) |
| `16..17` | 2 | `resetCount` (`uint16`, empty-window compaction count) |
| `18..19` | 2 | `txErrs` (`uint16`) |
| `20..21` | 2 | `pendingSlabs` (`uint16`) |
| `22` | 1 | `statusFlags` (`b0=charging`, `b1=stalled`, `b2=storageFull`, `b3=liveAudio`, `b4=interrupted`) |
| `23` | 1 | `lastEndReason` (`0=none`, `1=user`, `2=full`, `3=micDenied`, `4=micError`, `5=unexpected`) |
