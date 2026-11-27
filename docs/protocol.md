# SLV2 Wire & Storage Protocol

`solstone` transfers voice audio from the watch to the paired phone over
Garmin Connect IQ's `Communications.transmit()` channel using a compact,
strictly half-duplex binary framing protocol (`SLV2`), with optional 24-byte
local link-health frames (`SLVT`).

## 1. Design Constraints

- **Universal 8 KiB slab quantum:** Normal slabs flush once staged mono 16 kHz
  Ogg Opus payload reaches `>= 8,192 B` (chunk-aligned to ~9.05 KB average)
  plus a 24-byte big-endian header; segment-end (`FLAG_SEG_END`) and shutdown
  tail slabs may be shorter. This fits comfortably inside the 64 KB background
  `ServiceDelegate` memory budget (accounting for 2-3x transient serialization
  overhead) while achieving near-peak Bluetooth throughput (~8.7 KB/s burst,
  >2x real-time).
- **Lock-free single-writer `Application.Storage` ring:**
  - Data slots use integer keys `0..959` (`RING_CAP = 960`, ~8.7 MiB ceiling,
    safely below Connect IQ's 10 MiB storage limit, holding ~36-38 minutes of
    audio when away from the phone).
  - Key `-1` (`K_FG_META`, foreground sole writer):
    `[headSeq, fgAckedSeq, fgActive, modeId, segId, segEpoch, hbEpoch]`.
  - Key `-2` (`K_BG_META`, background sole writer):
    `[bgAckedSeq, lastSentSeq, wakeCount, lastWakeEpoch, lastErr]`.
  - Key `-3` (`K_TELEM`):
    `[batStartPct, segsDone, stWriteMaxMs, writeCount, isStalled, modeId]`.
  - Effective confirmed acknowledgement across both VMs is
    `max(fgAckedSeq, bgAckedSeq)`.
- **Zero-gap empty-window compaction:** Per-slab `Storage.deleteValue()` leaves
  tombstones that trigger multi-second synchronous compaction pauses on flash.
  Instead, after 120 slabs (~1.05 MB, every ~5 minutes), the watch drains its
  pending burst to `0` and calls `Storage.clearValues()` inside the ~2.5-second
  inter-slab window while audio continues uninterrupted in the 32-slot RAM ring,
  rewriting metadata cursors immediately. Undelivered slabs are never cleared or
  overwritten.

## 2. `SLV2` Audio Slab Header (24 Bytes, Big-Endian)

| Offset | Size | Type | Field | Description |
|---|---:|---|---|---|
| `0..3` | 4 | ASCII | `magic` | `"SLV2"` (`0x53 0x4C 0x56 0x32`) |
| `4` | 1 | `uint8` | `flags` | `b0=SEG_START`, `b1=SEG_END`, `b2=ACK_REQ`, `b3=MORE_PENDING`, `b4=BG_ORIGIN`, `b5..7=modeId` |
| `5` | 1 | `uint8` | `rateKhz` | Sample rate in kHz (`16` or `8`) |
| `6..7` | 2 | `uint16` | `segId` | Monotonic 5-minute segment counter |
| `8..11` | 4 | `uint32` | `seq` | Monotonic global slab sequence (idempotency and oldest-first ordering key) |
| `12..15` | 4 | `uint32` | `segEpoch` | Watch UTC epoch seconds at segment start |
| `16..19` | 4 | `uint32` | `relMs` | Milliseconds elapsed since segment start |
| `20..21` | 2 | `uint16` | `payloadLen` | Exact Ogg Opus payload byte count following byte 23 |
| `22..23` | 2 | `uint16` | `tag16` | 16-bit sampled integrity tag over payload bytes |

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
2. **Phone turn:** Validates `"SLV2"` magic and `tag16`, stores payload
   idempotently by `seq`, and sends **nothing** while `FLAG_ACK_REQ` is clear.
   Only when `FLAG_ACK_REQ` is set does the phone send one cumulative
   acknowledgement (`{"a": lastContiguousSeq}`).
3. **Background drain (`FLAG_BG_ORIGIN`):** When the foreground app exits with
   waiting slabs (or during active recording in `MODE_BG_DRAIN`),
   `VoiceBgService` wakes on 5-minute temporal events or phone wake messages
   (`onPhoneAppMessage`), drains up to 24 slabs or 22 seconds (~180 KB) via
   callback chaining (zero timers), stamps `FLAG_BG_ORIGIN` on each slab and
   adds `FLAG_ACK_REQ` (plus `FLAG_MORE_PENDING` if more slabs wait) on the
   final slab of the wake, and calls `Background.exit()`. When both
   `FLAG_BG_ORIGIN` and `FLAG_ACK_REQ` are set, the companion waits 2.5 seconds
   for the background VM to exit before sending `{"a": lastContiguousSeq}` as
   the next wake doorbell.

## 4. `SLVT` Segment Health Frame (24 Bytes, Big-Endian)

Emitted in foreground-TX modes (`0=FG_BURST`, `2=QUIET_BURST`) on 5-minute
segment boundaries and session stop inside the same half-duplex channel (not
sent in `1=BG_DRAIN`; zero HTTP calls, zero extra wakeups):

| Offset | Size | Field |
|---|---:|---|
| `0..3` | 4 | Magic `"SLVT"` (`0x53 0x4C 0x56 0x54`) |
| `4` | 1 | `modeId` (`0=FG_BURST`, `1=BG_DRAIN`, `2=QUIET_BURST`) |
| `5` | 1 | `batPct` (`0..100`) |
| `6..7` | 2 | `segId` (`uint16`) |
| `8..9` | 2 | `freeKb` (`uint16`, watch free heap in KiB) |
| `10..11` | 2 | `stWriteMaxMs` (`uint16`, max `Storage.setValue` duration in ms) |
| `12..13` | 2 | `droppedChunks` (`uint16`) |
| `14..15` | 2 | `bgWakeCount` (`uint16`) |
| `16..17` | 2 | `resetCount` (`uint16`, empty-window compaction count) |
| `18..19` | 2 | `txErrs` (`uint16`) |
| `20..21` | 2 | `pendingSlabs` (`uint16`) |
| `22..23` | 2 | `statusFlags` (`b0=charging`, `b1=stalled`, `b2=storageFull`, `b3=recording`) |
