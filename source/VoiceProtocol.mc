// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;

(:background)
module VoiceProto {
    // Wire protocol version exchanged in SLV3/SLVS headers and phone ACKs {"a": seq, "v": 1}
    const PROTO_VERSION as Number = 1;

    // Production foreground delivery mode (strict half-duplex burst + post-session BG drain)
    const MODE_FG_BURST as Number = 0;

    // Heartbeat staleness threshold (seconds) after which BG treats an active FG flag as crashed/evicted
    const FG_STALE_SEC as Number = 300;

    // Launch block reasons (Garmin closes non-apps-menu launches after ~2 minutes)
    const LAUNCH_OK as Number = 0;
    const LAUNCH_FROM_GLANCE as Number = 1;
    const LAUNCH_FROM_COMPLICATION as Number = 2;
    const LAUNCH_FROM_POST_INSTALL as Number = 3;

    // Owner-visible session phase (view snapshot + K_FACE[0])
    const PHASE_READY as Number = 0;
    const PHASE_STARTING as Number = 1;
    const PHASE_ACTIVE as Number = 2;
    const PHASE_STOPPING as Number = 3;

    // Worst-first single attention reason (view snapshot + K_FACE[1])
    const REASON_NONE as Number = 0;
    const REASON_MIC_PERMISSION as Number = 1;
    const REASON_MIC_STALLED as Number = 2;
    const REASON_STORAGE_FULL as Number = 3;
    const REASON_TIMEOUT_LAUNCH as Number = 4;
    const REASON_PHONE_TOO_OLD as Number = 5;
    const REASON_WATCH_TOO_OLD as Number = 6;

    // Last session end reasons persisted across restarts (never auto-restart; K_FACE[2])
    const END_NONE as Number = 0;
    const END_USER_STOP as Number = 1;
    const END_STORAGE_FULL as Number = 2;
    const END_MIC_DENIED as Number = 3;
    const END_MIC_ERROR as Number = 4;
    const END_UNEXPECTED as Number = 5;

    // Sentinel for unset sun-arc tzdb coordinates in K_SESSION_META
    const TZ_UNSET as Number = 99999;

    // Conservative phone-away audio holding capacity in seconds (~36 minutes at 3.7 KB/s)
    const HOLD_CAP_SEC as Number = 2160;

    // Universal 8 KiB slab quantum (fits 48 KB free BG RAM at 3x transient serialization)
    // Actual slabs average ~9.05 KB (chunk-aligned above 8192 B); 960 slots = ~8.7 MiB (<10 MiB Storage limit)
    const RING_CAP as Number = 960;
    const SLAB_TARGET_BYTES as Number = 8192;
    const HDR_SIZE as Number = 28;
    const STATUS_SIZE as Number = 24;
    const BURST_SLABS as Number = 8;
    const SEG_DURATION_MS as Number = 300000; // 5-minute segment rotation

    // Single-writer negative integer Storage keys (zero String churn, zero Symbol build-drift)
    // Effective confirmed ACK across both VMs = max(K_FG_META[1], K_BG_META[0])
    const K_FG_META as Number = -1;      // [headSeq, fgAckedSeq, fgActive, modeId, segId, segEpoch, hbEpoch]
    const K_BG_META as Number = -2;      // [bgAckedSeq, lastSentSeq, wakeCount, lastWakeEpoch, lastErr]
    const K_HEALTH as Number = -3;       // [batStartPct, segsDone, stWriteMaxMs, writeCount, isStalled, modeId]
    const K_FACE as Number = -4;         // [phase, reason, lastEnd, startEpochOrZero] (FG-only, written on transitions)
    const K_SESSION_META as Number = -5; // [lastEndReason, lastEndEpoch, phoneProtoVer, phoneEverAcked, lastPhoneAckEpoch, tzLat100, tzLon100]

    // SLV3 header flag bits (byte 5)
    const FLAG_SEG_START as Number = 1;
    const FLAG_SEG_END as Number = 2;
    const FLAG_ACK_REQ as Number = 4;
    const FLAG_MORE_PENDING as Number = 8;
    const FLAG_BG_ORIGIN as Number = 16;
    const FLAG_SEG_PARTIAL as Number = 32;

    // Compile-time log stripping (-r excludes :debug; zero System.println bytecode in release builds)
    (:debug)
    function vlog(msg as String) as Void {
        System.println(msg);
    }

    (:release)
    function vlog(msg as String) as Void {
    }

    // Fast 16-bit integrity tag sampling up to 16 evenly spaced payload bytes (constant O(1) VM opcodes)
    function fastTag16(bytes as ByteArray, offset as Number, len as Number) as Number {
        var h = len & 0xFFFF;
        if (len > 0) {
            var samples = (len < 16) ? len : 16;
            for (var k = 0; k < samples; k++) {
                var idx = (samples == 1) ? 0 : ((k * (len - 1)) / (samples - 1));
                var b = bytes[offset + idx] & 0xFF;
                h = ((h * 33) + b + k) & 0xFFFF;
            }
        }
        return h;
    }

    // Stamp 28-byte SLV3 header in-place into bytes 0..27 of a pre-allocated slab (zero extra copy):
    // 0..3: "SLV3" | 4: protoVer | 5: flags | 6..7: segId | 8..11: seq | 12..15: segEpoch |
    // 16..17: tzOffsetMin (int16) | 18..21: relMs | 22: rateKhz | 23: reserved | 24..25: payloadLen | 26..27: tag16
    function writeHeaderInPlace(
        slab as ByteArray,
        flags as Number,
        rateKhz as Number,
        segId as Number,
        seq as Number,
        segEpoch as Number,
        tzOffsetMin as Number,
        relMs as Number,
        payloadLen as Number,
        tag16 as Number,
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as Void {
        slab[0] = 0x53; // 'S'
        slab[1] = 0x4C; // 'L'
        slab[2] = 0x56; // 'V'
        slab[3] = 0x33; // '3'
        slab[4] = PROTO_VERSION & 0xFF;
        slab[5] = flags & 0xFF;

        encOpts[:offset] = 6;
        slab.encodeNumber(segId & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 8;
        slab.encodeNumber(seq, Lang.NUMBER_FORMAT_UINT32, encOpts);
        encOpts[:offset] = 12;
        slab.encodeNumber(segEpoch, Lang.NUMBER_FORMAT_UINT32, encOpts);
        encOpts[:offset] = 16;
        slab.encodeNumber(tzOffsetMin, Lang.NUMBER_FORMAT_SINT16, encOpts);
        encOpts[:offset] = 18;
        slab.encodeNumber(relMs, Lang.NUMBER_FORMAT_UINT32, encOpts);
        slab[22] = rateKhz & 0xFF;
        slab[23] = 0;
        encOpts[:offset] = 24;
        slab.encodeNumber(payloadLen & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 26;
        slab.encodeNumber(tag16 & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
    }

    // Convenience helper allocating a standalone 28-byte SLV3 header
    function buildHeader(
        flags as Number,
        rateKhz as Number,
        segId as Number,
        seq as Number,
        segEpoch as Number,
        tzOffsetMin as Number,
        relMs as Number,
        payloadLen as Number,
        tag16 as Number,
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as ByteArray {
        var hdr = new [HDR_SIZE]b;
        writeHeaderInPlace(hdr, flags, rateKhz, segId, seq, segEpoch, tzOffsetMin, relMs, payloadLen, tag16, encOpts);
        return hdr;
    }

    // Build 24-byte SLVS local watch-to-phone link-status frame (strictly local BLE, zero internet/analytics):
    // 0..3: "SLVS" | 4: protoVer | 5: batPct | 6..7: segId | 8..9: freeKb | 10..11: writeMaxMs |
    // 12..13: dropped | 14..15: bgWakes | 16..17: resets | 18..19: txErrs | 20..21: pending | 22: statusFlags | 23: lastEndReason
    function buildStatusFrame(
        batPct as Number,
        segId as Number,
        freeKb as Number,
        stWriteMaxMs as Number,
        dropped as Number,
        bgWakes as Number,
        resets as Number,
        txErrs as Number,
        pending as Number,
        statusFlags as Number,
        lastEndReason as Number,
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as ByteArray {
        var f = new [STATUS_SIZE]b;
        f[0] = 0x53; // 'S'
        f[1] = 0x4C; // 'L'
        f[2] = 0x56; // 'V'
        f[3] = 0x53; // 'S'
        f[4] = PROTO_VERSION & 0xFF;
        f[5] = batPct & 0xFF;

        var clampedW = (stWriteMaxMs > 65535) ? 65535 : ((stWriteMaxMs < 0) ? 0 : stWriteMaxMs);
        encOpts[:offset] = 6;
        f.encodeNumber(segId & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 8;
        f.encodeNumber(freeKb & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 10;
        f.encodeNumber(clampedW, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 12;
        f.encodeNumber(dropped & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 14;
        f.encodeNumber(bgWakes & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 16;
        f.encodeNumber(resets & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 18;
        f.encodeNumber(txErrs & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 20;
        f.encodeNumber(pending & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        f[22] = statusFlags & 0xFF;
        f[23] = lastEndReason & 0xFF;
        return f;
    }

    // Mutate SLV3 header flags (byte 5) in-place (zero ByteArray allocation or copy)
    function patchHeaderFlags(slab as ByteArray, orFlags as Number) as Void {
        if (slab.size() >= HDR_SIZE) {
            slab[5] = (slab[5] | orFlags) & 0xFF;
        }
    }

    // Parse cumulative ACK sequence from phone message: Number, [seq], {"a" => seq}, or {"seq" => seq}
    function parseAckSeq(data as Object?) as Number {
        if (data == null) {
            return -1;
        }
        if (data instanceof Number) {
            return data as Number;
        }
        if (data instanceof Array) {
            var arr = data as Array;
            if (arr.size() > 0 && arr[0] instanceof Number) {
                return arr[0] as Number;
            }
            return -1;
        }
        if (data instanceof Dictionary) {
            var d = data as Dictionary;
            var v = d["a"];
            if (v instanceof Number) {
                return v as Number;
            }
            v = d["seq"];
            if (v instanceof Number) {
                return v as Number;
            }
        }
        return -1;
    }

    // Parse phone protocol version from {"a" => seq, "v" => ver} (returns -1 if absent)
    function parseAckVersion(data as Object?) as Number {
        if (data instanceof Dictionary) {
            var d = data as Dictionary;
            var v = d["v"];
            if (v instanceof Number) {
                return v as Number;
            }
        }
        return -1;
    }

    // Parse optional phone tzdb representative point {"z" => [lat100, lon100]} for the sun arc
    // (no GPS/location API; strictly phone system timezone reference point in hundredths of a degree).
    function parseAckTzPoint(data as Object?) as Array<Number>? {
        if (data instanceof Dictionary) {
            var d = data as Dictionary;
            var raw = d["z"];
            if (raw instanceof Array) {
                var arr = raw as Array;
                if (arr.size() == 2 && arr[0] instanceof Number && arr[1] instanceof Number) {
                    var lat100 = arr[0] as Number;
                    var lon100 = arr[1] as Number;
                    if (lat100 >= -9000 && lat100 <= 9000 && lon100 >= -18000 && lon100 <= 18000) {
                        return [lat100, lon100] as Array<Number>;
                    }
                }
            }
        }
        return null;
    }

    // Lock-free SPSC metadata helpers (defensive try/catch for post-reboot Storage resilience)
    function readIntArray(key as Number, expectedLen as Number) as Array<Number>? {
        try {
            var raw = Storage.getValue(key);
            if (raw instanceof Array) {
                var arr = raw as Array;
                if (arr.size() >= expectedLen) {
                    var out = new Array<Number>[expectedLen];
                    for (var i = 0; i < expectedLen; i++) {
                        if (arr[i] instanceof Number) {
                            out[i] = arr[i] as Number;
                        } else {
                            return null;
                        }
                    }
                    return out;
                }
            }
        } catch (_) {}
        return null;
    }

    function writeIntArray(key as Number, vals as Array<Number>) as Boolean {
        try {
            Storage.setValue(key, vals as Storage.ValueType);
            return true;
        } catch (_) {
            return false;
        }
    }
}

// Foreground-only read-only view snapshot (excluded from 64 KB (:background) VM).
class VoiceSnapshot {
    public var phase as Number;
    public var reason as Number;
    public var lastEnd as Number;
    public var lastEndEpoch as Number;
    public var startEpoch as Number?;
    public var heldSec as Number;
    public var capSec as Number;
    public var pendingSlabs as Number;
    public var phoneLink as Boolean;
    public var phoneLinked as Boolean;
    public var lastPhoneEpoch as Number?;
    public var tzLat100 as Number?;
    public var tzLon100 as Number?;
    public var touchLocked as Boolean;
    public var interrupted as Boolean;
    public var launchBlockReason as Number;

    public function initialize(
        pPhase as Number,
        pReason as Number,
        pLastEnd as Number,
        pLastEndEpoch as Number,
        pStartEpoch as Number?,
        pHeldSec as Number,
        pCapSec as Number,
        pPendingSlabs as Number,
        pPhoneLink as Boolean,
        pPhoneLinked as Boolean,
        pLastPhoneEpoch as Number?,
        pTzLat100 as Number?,
        pTzLon100 as Number?,
        pTouchLocked as Boolean,
        pInterrupted as Boolean,
        pLaunchBlockReason as Number
    ) {
        phase = pPhase;
        reason = pReason;
        lastEnd = pLastEnd;
        lastEndEpoch = pLastEndEpoch;
        startEpoch = pStartEpoch;
        heldSec = pHeldSec;
        capSec = pCapSec;
        pendingSlabs = pPendingSlabs;
        phoneLink = pPhoneLink;
        phoneLinked = pPhoneLinked;
        lastPhoneEpoch = pLastPhoneEpoch;
        tzLat100 = pTzLat100;
        tzLon100 = pTzLon100;
        touchLocked = pTouchLocked;
        interrupted = pInterrupted;
        launchBlockReason = pLaunchBlockReason;
    }
}
