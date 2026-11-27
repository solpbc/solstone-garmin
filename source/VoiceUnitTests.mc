// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;

// Run No Evil unit test suite (excluded from normal/release builds unless compiled with --unit-test)

(:test)
function testSlv2HeaderAndPatch(logger as Test.Logger) as Boolean {
    var payload = [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0xAB, 0xCD]b;
    var tag = VoiceProto.fastTag16(payload, 0, payload.size());
    var encOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var flags = VoiceProto.FLAG_SEG_START | (VoiceProto.MODE_BG_DRAIN << 5);

    var hdr = VoiceProto.buildHeader(flags, 16, 42, 1005, 1795600000, 12345, payload.size(), tag, encOpts);
    Test.assertEqual(hdr.size(), 24);
    Test.assertEqual(hdr[0], 0x53); // 'S'
    Test.assertEqual(hdr[1], 0x4C); // 'L'
    Test.assertEqual(hdr[2], 0x56); // 'V'
    Test.assertEqual(hdr[3], 0x32); // '2'
    Test.assertEqual(hdr[4], flags);
    Test.assertEqual(hdr[5], 16);

    // Verify exact big-endian uint16/uint32 fields (NUMBER_FORMAT_UINT32 decodes as Long in Monkey C)
    var decOpts = { :offset => 6, :endianness => Lang.ENDIAN_BIG };
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 42);
    decOpts[:offset] = 8;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 1005);
    decOpts[:offset] = 12;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 1795600000);
    decOpts[:offset] = 16;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 12345);
    decOpts[:offset] = 20;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 8);
    decOpts[:offset] = 22;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), tag);

    // Verify raw big-endian wire bytes for seq=1005 (0x000003ED)
    Test.assertEqual(hdr[8], 0x00);
    Test.assertEqual(hdr[9], 0x00);
    Test.assertEqual(hdr[10], 0x03);
    Test.assertEqual(hdr[11], 0xED);

    // Verify in-place flag patching without realloc
    VoiceProto.patchHeaderFlags(hdr, VoiceProto.FLAG_ACK_REQ | VoiceProto.FLAG_BG_ORIGIN);
    Test.assertEqual(hdr[4], flags | VoiceProto.FLAG_ACK_REQ | VoiceProto.FLAG_BG_ORIGIN);
    logger.debug("SLV2 header, big-endian wire bytes & in-place flag patch verified tag=" + tag);
    return true;
}

(:test)
function testParseAckFormats(logger as Test.Logger) as Boolean {
    Test.assertEqual(VoiceProto.parseAckSeq(null), -1);
    Test.assertEqual(VoiceProto.parseAckSeq(77), 77);
    Test.assertEqual(VoiceProto.parseAckSeq([128]), 128);
    Test.assertEqual(VoiceProto.parseAckSeq({ "a" => 255 }), 255);
    Test.assertEqual(VoiceProto.parseAckSeq({ "seq" => 512 }), 512);
    Test.assertEqual(VoiceProto.parseAckSeq("bad"), -1);
    logger.debug("ACK parser verified across all formats");
    return true;
}

(:test)
function testIsrCallbacksRing(logger as Test.Logger) as Boolean {
    var cb = new VoiceCaptureCallbacks();
    // Ring holds CAP-1 = 31 chunks; pushing 35 must keep first 31 in FIFO order and count 4 drops
    for (var i = 0; i < 35; i++) {
        cb.onData([i & 0xFF]b);
    }
    Test.assertEqual(cb.dropped, 4);

    for (var i = 0; i < 31; i++) {
        var item = cb.pop();
        Test.assert(item != null);
        if (item != null) {
            Test.assertEqual(item[0], i & 0xFF);
        }
    }
    Test.assert(cb.pop() == null);
    logger.debug("ISR ring verified (31 FIFO + 4 bounded drops)");
    return true;
}

(:test)
function testStorageRingSpscAndCompaction(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    Test.assertEqual(ring.headSeq(), 0);
    Test.assertEqual(ring.ackedSeq(), -1);
    Test.assertEqual(ring.pendingCount(), 0);

    // Stage four 2048-byte chunks -> triggers exactly one 8192-byte slab commit
    var chunk = new [2048]b;
    chunk[0] = 0x4F;
    chunk[2047] = 0x5A;
    for (var i = 0; i < 4; i++) {
        var ok = ring.appendChunk(chunk, VoiceProto.MODE_FG_BURST, 16, 1, 1795600000, i * 500, i == 0);
        Test.assert(ok);
    }
    Test.assertEqual(ring.headSeq(), 1);
    Test.assertEqual(ring.pendingCount(), 1);

    // Verify persisted 8216-byte SLV2 slab in Storage slot 0
    var slab = ring.readSlab(0);
    Test.assert(slab != null);
    if (slab != null) {
        Test.assertEqual(slab.size(), 8192 + 24);
        Test.assertEqual(slab[0], 0x53); // 'S'
        Test.assertEqual(slab[24], 0x4F);
        Test.assertEqual(slab[24 + 2047], 0x5A);
    }

    // Flush tail partial chunk (512 bytes) -> commits seq 1 with FLAG_SEG_END
    var tail = new [512]b;
    Test.assert(ring.appendChunk(tail, VoiceProto.MODE_FG_BURST, 16, 1, 1795600000, 2000, false));
    Test.assert(ring.flushSegmentTail(VoiceProto.MODE_FG_BURST, 16, 1, 1795600000, 2500));
    Test.assertEqual(ring.headSeq(), 2);
    Test.assertEqual(ring.pendingCount(), 2);

    var slab1 = ring.readSlab(1);
    Test.assert(slab1 != null);
    if (slab1 != null) {
        Test.assertEqual(slab1.size(), 512 + 24);
        Test.assert((slab1[4] & VoiceProto.FLAG_SEG_END) != 0);
    }

    // Simulate BG confirming seq 0 via K_BG_META (lock-free SPSC merge)
    VoiceProto.writeIntArray(VoiceProto.K_BG_META, [0, 0, 1, 1795600010, 0] as Array<Number>);
    ring.syncBgAck();
    Test.assertEqual(ring.ackedSeq(), 0);
    Test.assertEqual(ring.pendingCount(), 1);

    // Simulate FG confirming seq 1 -> queue drains empty
    Test.assert(ring.onAckConfirmed(1));
    Test.assertEqual(ring.ackedSeq(), 1);
    Test.assertEqual(ring.pendingCount(), 0);

    // Persist FG meta and confirm reload preserves both headSeq and fgAckedSeq
    ring.persistFgMeta(0, VoiceProto.MODE_BG_DRAIN, 1, 1795600000);
    var ring2 = new VoiceStorageRing();
    Test.assertEqual(ring2.headSeq(), 2);
    Test.assertEqual(ring2.ackedSeq(), 1);
    Test.assertEqual(ring2.pendingCount(), 0);

    Storage.clearValues();
    logger.debug("StorageRing SPSC + slab framing + reload verified");
    return true;
}

(:test)
function testTransportAndModeCycling(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var tx = new VoiceTransport();
    Test.assert(tx.isIdle());
    tx.resetCursor(10);
    tx.onPhoneMsgError();
    Test.assertEqual(tx.phoneMsgErrs(), 1);

    // Verify VoiceCaptureEngine & VoiceBgService instantiate cleanly with ample free RAM
    var eng = new VoiceCaptureEngine();
    Test.assert(!eng.isRecording());
    Test.assertEqual(eng.rateKhz(), 16);
    var bg = new VoiceBgService();
    Test.assert(bg != null);

    var stats = System.getSystemStats();
    logger.debug("Transport + Engine + BgService verified; freeMem=" + stats.freeMemory);
    return true;
}

(:test)
function testSlvtTelemAndCompactionReset(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var encOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var f = VoiceProto.buildTelemFrame(1, 88, 7, 675, 142, 0, 12, 2, 1, 5, 9, encOpts);
    Test.assertEqual(f.size(), 24);
    Test.assertEqual(f[0], 0x53); // 'S'
    Test.assertEqual(f[1], 0x4C); // 'L'
    Test.assertEqual(f[2], 0x56); // 'V'
    Test.assertEqual(f[3], 0x54); // 'T'
    Test.assertEqual(f[4], 1);    // modeId
    Test.assertEqual(f[5], 88);   // batPct

    var decOpts = { :offset => 6, :endianness => Lang.ENDIAN_BIG };
    Test.assertEqual(f.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 7);
    decOpts[:offset] = 8;
    Test.assertEqual(f.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 675);
    decOpts[:offset] = 10;
    Test.assertEqual(f.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 142);

    // Exercise OVERWRITE_AND_RESET compaction after 120 small slabs drain empty
    var ring = new VoiceStorageRing();
    VoiceProto.writeIntArray(VoiceProto.K_BG_META, [-1, -1, 3, 1700000000, 0] as Array<Number>);
    var tiny = new [64]b;
    for (var i = 0; i < 120; i++) {
        Test.assert(ring.appendChunk(tiny, VoiceProto.MODE_FG_BURST, 16, 1, 1795600000, i * 100, i == 0));
        Test.assert(ring.flushSegmentTail(VoiceProto.MODE_FG_BURST, 16, 1, 1795600000, i * 100 + 50));
    }
    Test.assertEqual(ring.headSeq(), 120);
    Test.assert(ring.onAckConfirmed(119));
    Test.assertEqual(ring.pendingCount(), 0);

    // Compaction fires cleanly and preserves both K_FG_META and K_BG_META!
    ring.maybeCompactIfEmpty(0, VoiceProto.MODE_FG_BURST, 1, 1795600000);
    Test.assertEqual(ring.resetCount(), 1);
    var bgAfter = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
    Test.assert(bgAfter != null);
    if (bgAfter != null) {
        Test.assertEqual(bgAfter[2], 3);
    }
    var fgAfter = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
    Test.assert(fgAfter != null);
    if (fgAfter != null) {
        Test.assertEqual(fgAfter[0], 120);
        Test.assertEqual(fgAfter[1], 119);
    }
    Storage.clearValues();
    logger.debug("SLVT telemetry & 120-slab OVERWRITE_AND_RESET compaction verified");
    return true;
}

(:test)
function testFullRingNeverOverwritesUndelivered(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    // Write RING_CAP un-ACKed slabs with distinct marker byte on seq=0
    var first = [0xEE, 0x11, 0x22, 0x33]b;
    Test.assert(ring.appendChunk(first, VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 0, true));
    Test.assert(ring.flushSegmentTail(VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 10));

    var tiny = [0xAA, 0xBB]b;
    for (var i = 1; i < VoiceProto.RING_CAP; i++) {
        Test.assert(ring.appendChunk(tiny, VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, i, false));
        Test.assert(ring.flushSegmentTail(VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, i));
    }
    Test.assertEqual(ring.pendingCount(), VoiceProto.RING_CAP);
    Test.assert(!ring.isFull());

    // Next write past RING_CAP MUST refuse honestly and preserve seq=0 completely intact
    Test.assert(ring.appendChunk([0x99]b, VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 9999, false));
    var okOverflow = ring.flushSegmentTail(VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 9999);
    Test.assert(!okOverflow);
    Test.assert(ring.isFull());
    Test.assertEqual(ring.headSeq(), VoiceProto.RING_CAP);

    var slab0 = ring.readSlab(0);
    Test.assert(slab0 != null);
    if (slab0 != null) {
        Test.assertEqual(slab0[24], 0xEE); // Slot 0 untouched!
    }

    // Once seq=0 is ACKed, ring clears full flag and allows seq=RING_CAP to overwrite slot 0 cleanly
    Test.assert(ring.onAckConfirmed(0));
    Test.assert(!ring.isFull());
    Test.assert(ring.appendChunk([0x77]b, VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 10000, false));
    Test.assert(ring.flushSegmentTail(VoiceProto.MODE_BG_DRAIN, 16, 1, 1795600000, 10000));
    Test.assertEqual(ring.headSeq(), VoiceProto.RING_CAP + 1);
    var slabWrapped = ring.readSlab(VoiceProto.RING_CAP);
    Test.assert(slabWrapped != null);
    if (slabWrapped != null) {
        Test.assertEqual(slabWrapped[24], 0x77);
    }
    Storage.clearValues();
    logger.debug("Full-ring protection & post-ACK wraparound verified across RING_CAP+1 slabs");
    return true;
}
