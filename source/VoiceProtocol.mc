// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;

(:background)
module VoiceProto {
    // Selectable delivery modes
    const MODE_FG_BURST as Number = 0;    // Mode A: Decoupled FG strict half-duplex burst (BG disabled while recording)
    const MODE_BG_DRAIN as Number = 1;    // Mode B: 100% radio-silent FG + passive separate-VM ServiceDelegate burst drainer
    const MODE_QUIET_BURST as Number = 2; // Mode C: Zero-overlap time-division (Capture.stop -> full BLE burst -> Capture.start)

    // Universal 8 KB slab quantum (fits 48 KB free BG RAM at 3x transient serialization + peaks 8.7 KB/s BLE)
    // Actual slabs average ~9.05 KB (chunk-aligned above 8192 B); 960 slots = ~8.7 MiB, safely under 10 MiB Storage quota
    const RING_CAP as Number = 960;            // Integer keys 0..959 (~38-40m offline @ 16 kHz / ~55m @ 8 kHz)
    const SLAB_TARGET_BYTES as Number = 8192;  // 8 KiB Opus payload per slab (~2.2-4.3 s of 16 kHz Opus)
    const HDR_SIZE as Number = 24;
    const BURST_SLABS as Number = 8;           // K=8 slabs (~64 KB) per half-duplex burst before yielding for 1 cumulative ACK
    const SEG_DURATION_MS as Number = 300000;  // 5-minute segment rotation

    // Single-writer negative integer Storage keys (zero String churn, zero Symbol build-drift)
    // Effective confirmed ACK across both VMs = max(K_FG_META[1], K_BG_META[0]) — zero write races!
    const K_FG_META as Number = -1; // [headSeq, fgAckedSeq, fgActive, modeId, segId, segEpoch, hbEpoch]
    const K_BG_META as Number = -2; // [bgAckedSeq, lastSentSeq, wakeCount, lastWakeEpoch, lastErr]
    const K_TELEM as Number = -3;   // [batStartPct, segsDone, stWriteMaxMs, writeCount, isStalled, modeId]

    // SLV2 header flag bits (byte 4)
    const FLAG_SEG_START as Number = 1;
    const FLAG_SEG_END as Number = 2;
    const FLAG_ACK_REQ as Number = 4;
    const FLAG_MORE_PENDING as Number = 8;
    const FLAG_BG_ORIGIN as Number = 16;

    // Compile-time log stripping (-r excludes :debug; zero System.println bytecode in release builds)
    (:debug)
    function vlog(msg as String) as Void {
        System.println(msg);
    }

    (:release)
    function vlog(msg as String) as Void {
    }

    function modeName(mode as Number) as String {
        if (mode == MODE_FG_BURST) { return "A: FG Burst"; }
        if (mode == MODE_BG_DRAIN) { return "B: BG Drain"; }
        return "C: Quiet Burst";
    }

    // Fast 16-bit integrity checksum sampling up to 16 evenly spaced bytes (constant O(1) VM opcodes)
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

    // Stamp 24-byte SLV2 header in-place into bytes 0..23 of a pre-allocated slab (zero extra copy!)
    function writeHeaderInPlace(
        slab as ByteArray,
        flags as Number,
        rateKhz as Number,
        segId as Number,
        seq as Number,
        segEpoch as Number,
        relMs as Number,
        payloadLen as Number,
        tag16 as Number,
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as Void {
        slab[0] = 0x53; // 'S'
        slab[1] = 0x4C; // 'L'
        slab[2] = 0x56; // 'V'
        slab[3] = 0x32; // '2'
        slab[4] = flags & 0xFF;
        slab[5] = rateKhz & 0xFF;

        encOpts[:offset] = 6;
        slab.encodeNumber(segId & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 8;
        slab.encodeNumber(seq, Lang.NUMBER_FORMAT_UINT32, encOpts);
        encOpts[:offset] = 12;
        slab.encodeNumber(segEpoch, Lang.NUMBER_FORMAT_UINT32, encOpts);
        encOpts[:offset] = 16;
        slab.encodeNumber(relMs, Lang.NUMBER_FORMAT_UINT32, encOpts);
        encOpts[:offset] = 20;
        slab.encodeNumber(payloadLen & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        encOpts[:offset] = 22;
        slab.encodeNumber(tag16 & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
    }

    // Convenience helper allocating a standalone 24-byte SLV2 header
    function buildHeader(
        flags as Number,
        rateKhz as Number,
        segId as Number,
        seq as Number,
        segEpoch as Number,
        relMs as Number,
        payloadLen as Number,
        tag16 as Number,
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as ByteArray {
        var hdr = new [HDR_SIZE]b;
        writeHeaderInPlace(hdr, flags, rateKhz, segId, seq, segEpoch, relMs, payloadLen, tag16, encOpts);
        return hdr;
    }

    // Build 24-byte SLVT binary telemetry frame (sent inside half-duplex turn on segment seal; zero HTTP/JSON)
    function buildTelemFrame(
        modeId as Number,
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
        encOpts as { :offset as Number, :endianness as Lang.Endian }
    ) as ByteArray {
        var f = new [HDR_SIZE]b;
        f[0] = 0x53; // 'S'
        f[1] = 0x4C; // 'L'
        f[2] = 0x56; // 'V'
        f[3] = 0x54; // 'T'
        f[4] = modeId & 0xFF;
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
        encOpts[:offset] = 22;
        f.encodeNumber(statusFlags & 0xFFFF, Lang.NUMBER_FORMAT_UINT16, encOpts);
        return f;
    }

    // Mutate header flags in-place (zero ByteArray allocation or copy)
    function patchHeaderFlags(slab as ByteArray, orFlags as Number) as Void {
        if (slab.size() >= HDR_SIZE) {
            slab[4] = (slab[4] | orFlags) & 0xFF;
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
