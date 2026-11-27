// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application.Storage;
import Toybox.Audio.Capture;
import Toybox.Lang;
import Toybox.System;
import Toybox.Test;
import Toybox.Time;

// Automated Connect IQ Run No Evil unit test suite (--unit-test only; stripped from release builds)

(:test)
function testSlv3HeaderTzAndPatch(logger as Test.Logger) as Boolean {
    var payload = [0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0xAB, 0xCD]b;
    var tag = VoiceProto.fastTag16(payload, 0, payload.size());
    var tag2 = VoiceProto.fastTag16(payload, 0, payload.size());
    Test.assertEqual(tag, tag2);
    Test.assertEqual(tag, 13358);

    // Negative UTC offset (-420 min = UTC-07:00) + PARTIAL flag
    var encOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var decOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var hdr = VoiceProto.buildHeader(
        VoiceProto.FLAG_SEG_START | VoiceProto.FLAG_SEG_PARTIAL,
        16, 42, 1001, 1795651200, -420, 12500, payload.size(), tag, encOpts
    );
    Test.assertEqual(hdr.size(), VoiceProto.HDR_SIZE);
    Test.assertEqual(hdr[0], 0x53); // 'S'
    Test.assertEqual(hdr[1], 0x4C); // 'L'
    Test.assertEqual(hdr[2], 0x56); // 'V'
    Test.assertEqual(hdr[3], 0x33); // '3'
    Test.assertEqual(hdr[4], VoiceProto.PROTO_VERSION);
    Test.assertEqual(hdr[5], VoiceProto.FLAG_SEG_START | VoiceProto.FLAG_SEG_PARTIAL);

    decOpts[:offset] = 6;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 42);
    decOpts[:offset] = 8;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 1001);
    decOpts[:offset] = 12;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 1795651200);
    decOpts[:offset] = 16;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_SINT16, decOpts).toNumber(), -420);
    decOpts[:offset] = 18;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT32, decOpts).toNumber(), 12500);
    Test.assertEqual(hdr[22], 16);
    decOpts[:offset] = 24;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), payload.size());
    decOpts[:offset] = 26;
    Test.assertEqual(hdr.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), tag);

    // Positive non-hour UTC offset (+345 min = UTC+05:45 Nepal)
    var hdrPos = VoiceProto.buildHeader(0, 16, 1, 0, 1795651200, 345, 0, 8, tag, encOpts);
    decOpts[:offset] = 16;
    Test.assertEqual(hdrPos.decodeNumber(Lang.NUMBER_FORMAT_SINT16, decOpts).toNumber(), 345);

    // In-place flag patching must mutate byte 5 without touching protoVer byte 4
    VoiceProto.patchHeaderFlags(hdr, VoiceProto.FLAG_ACK_REQ | VoiceProto.FLAG_BG_ORIGIN);
    Test.assertEqual(hdr[4], VoiceProto.PROTO_VERSION);
    Test.assertEqual(
        hdr[5],
        VoiceProto.FLAG_SEG_START | VoiceProto.FLAG_SEG_PARTIAL | VoiceProto.FLAG_ACK_REQ | VoiceProto.FLAG_BG_ORIGIN
    );
    logger.debug("SLV3 28B header, signed tzOffsetMin & in-place flag patch verified tag=" + tag);
    return true;
}

(:test)
function testParseAckAndVersionFormats(logger as Test.Logger) as Boolean {
    Test.assertEqual(VoiceProto.parseAckSeq(null), -1);
    Test.assertEqual(VoiceProto.parseAckSeq(7), 7);
    Test.assertEqual(VoiceProto.parseAckSeq([19]), 19);
    Test.assertEqual(VoiceProto.parseAckSeq({ "a" => 42, "v" => 1 }), 42);
    Test.assertEqual(VoiceProto.parseAckSeq({ "seq" => 108 }), 108);
    Test.assertEqual(VoiceProto.parseAckSeq("bad"), -1);

    Test.assertEqual(VoiceProto.parseAckVersion({ "a" => 42, "v" => 1 }), 1);
    Test.assertEqual(VoiceProto.parseAckVersion({ "a" => 42, "v" => 2 }), 2);
    Test.assertEqual(VoiceProto.parseAckVersion({ "a" => 42 }), -1);
    Test.assertEqual(VoiceProto.parseAckVersion(7), -1);
    logger.debug("ACK sequence + protocol version parser verified");
    return true;
}

(:test)
function testIsrCallbacksRing(logger as Test.Logger) as Boolean {
    var cb = new VoiceCaptureCallbacks();
    for (var i = 0; i < 35; i++) {
        var b = [i & 0xFF]b;
        cb.onData(b);
    }
    Test.assertEqual(cb.dropped, 4);
    for (var j = 0; j < 31; j++) {
        var popped = cb.pop();
        Test.assert(popped != null);
        Test.assertEqual((popped as ByteArray)[0], j & 0xFF);
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

    var chunk2k = new [2048]b;
    for (var i = 0; i < 2048; i++) {
        chunk2k[i] = (i * 7 + 3) & 0xFF;
    }
    for (var c = 0; c < 4; c++) {
        Test.assert(ring.appendChunk(chunk2k, 16, 1, 1795651200, -420, c * 500, c == 0));
    }
    Test.assertEqual(ring.headSeq(), 1);
    Test.assertEqual(ring.pendingCount(), 1);

    var s0 = ring.readSlab(0);
    Test.assert(s0 != null);
    Test.assertEqual((s0 as ByteArray).size(), VoiceProto.HDR_SIZE + 8192);
    Test.assertEqual((s0 as ByteArray)[0], 0x53);
    Test.assertEqual((s0 as ByteArray)[3], 0x33);

    // Partial tail flush (< 8192 B) stamps FLAG_SEG_END | FLAG_SEG_PARTIAL
    var tail512 = new [512]b;
    Test.assert(ring.appendChunk(tail512, 16, 1, 1795651200, -420, 2000, false));
    Test.assert(ring.flushSegmentTail(16, 1, 1795651200, -420, 2500, true));
    Test.assertEqual(ring.headSeq(), 2);
    var s1 = ring.readSlab(1) as ByteArray;
    Test.assertEqual(s1.size(), VoiceProto.HDR_SIZE + 512);
    Test.assert((s1[5] & VoiceProto.FLAG_SEG_END) != 0);
    Test.assert((s1[5] & VoiceProto.FLAG_SEG_PARTIAL) != 0);

    // Cumulative ACK advances oldest-first cursor cleanly
    Test.assert(ring.onAckConfirmed(0));
    Test.assertEqual(ring.pendingCount(), 1);
    Test.assert(ring.onAckConfirmed(1));
    Test.assertEqual(ring.pendingCount(), 0);
    ring.persistFgMeta(0, 1, 1795651200);

    var ring2 = new VoiceStorageRing();
    Test.assertEqual(ring2.headSeq(), 2);
    Test.assertEqual(ring2.ackedSeq(), 1);
    Test.assertEqual(ring2.pendingCount(), 0);

    Storage.clearValues();
    logger.debug("StorageRing SPSC + SLV3 tz/partial framing + reload verified");
    return true;
}

(:test)
function testFullRingNeverOverwritesUndelivered(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    var chunk8k = new [8192]b;
    for (var i = 0; i < VoiceProto.RING_CAP; i++) {
        chunk8k[0] = i & 0xFF;
        chunk8k[1] = (i >> 8) & 0xFF;
        Test.assert(ring.appendChunk(chunk8k, 16, 1, 1795651200, -420, i * 2000, i == 0));
    }
    Test.assertEqual(ring.pendingCount(), VoiceProto.RING_CAP);
    Test.assert(!ring.isFull());

    // Slab RING_CAP + 1 must fail honestly and leave slot 0 untouched
    chunk8k[0] = 0xEE;
    chunk8k[1] = 0xEE;
    Test.assert(!ring.appendChunk(chunk8k, 16, 1, 1795651200, -420, 999999, false));
    Test.assert(ring.isFull());
    Test.assertEqual(ring.headSeq(), VoiceProto.RING_CAP);

    var slot0 = ring.readSlab(0) as ByteArray;
    Test.assertEqual(slot0[VoiceProto.HDR_SIZE], 0x00);
    Test.assertEqual(slot0[VoiceProto.HDR_SIZE + 1], 0x00);

    // After ACK frees slot 0, full flag clears and wraparound write succeeds
    Test.assert(ring.onAckConfirmed(0));
    Test.assert(!ring.isFull());
    Test.assert(ring.appendChunk(chunk8k, 16, 1, 1795651200, -420, 999999, false));
    Test.assertEqual(ring.headSeq(), VoiceProto.RING_CAP + 1);

    Storage.clearValues();
    logger.debug("Full-ring protection & post-ACK wraparound verified across RING_CAP+1 slabs");
    return true;
}

(:test)
function testCompactionOnlyWhenEmpty(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    var chunk8k = new [8192]b;
    for (var i = 0; i < 120; i++) {
        Test.assert(ring.appendChunk(chunk8k, 16, 1, 1795651200, -420, i * 2000, i == 0));
    }
    Test.assert(ring.needsCompaction());
    // Must NOT compact while slabs remain unacknowledged
    ring.maybeCompactIfEmpty(1, 1, 1795651200);
    Test.assertEqual(ring.resetCount(), 0);
    Test.assertEqual(ring.pendingCount(), 120);

    // Once ACKed empty, compaction runs and preserves K_FACE (-4), K_SESSION_META (-5), and cursors
    Test.assert(ring.writeFaceState(VoiceProto.PHASE_ACTIVE, VoiceProto.REASON_NONE, VoiceProto.END_NONE, 1795651200));
    VoiceProto.writeIntArray(VoiceProto.K_SESSION_META, [VoiceProto.END_USER_STOP, 1795651500, 1, 1, 1795651400, 3974, -10498]);
    Test.assert(ring.onAckConfirmed(119));
    ring.maybeCompactIfEmpty(1, 1, 1795651200);
    Test.assertEqual(ring.resetCount(), 1);
    Test.assert(!ring.needsCompaction());

    var face = VoiceProto.readIntArray(VoiceProto.K_FACE, 4);
    Test.assert(face != null);
    Test.assertEqual((face as Array<Number>)[0], VoiceProto.PHASE_ACTIVE);

    var sm = VoiceProto.readIntArray(VoiceProto.K_SESSION_META, 7);
    Test.assert(sm != null);
    Test.assertEqual((sm as Array<Number>)[0], VoiceProto.END_USER_STOP);
    Test.assertEqual((sm as Array<Number>)[4], 1795651400);
    Test.assertEqual((sm as Array<Number>)[5], 3974);

    Storage.clearValues();
    logger.debug("Empty-window compaction guard & K_SESSION_META preservation verified");
    return true;
}

(:test)
function testSlvsStatusFrame(logger as Test.Logger) as Boolean {
    var encOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var decOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
    var frame = VoiceProto.buildStatusFrame(
        87, 12, 742, 48, 0, 5, 2, 1, 14, 9, VoiceProto.END_STORAGE_FULL, encOpts
    );
    Test.assertEqual(frame.size(), VoiceProto.STATUS_SIZE);
    Test.assertEqual(frame[0], 0x53); // 'S'
    Test.assertEqual(frame[1], 0x4C); // 'L'
    Test.assertEqual(frame[2], 0x56); // 'V'
    Test.assertEqual(frame[3], 0x53); // 'S'
    Test.assertEqual(frame[4], VoiceProto.PROTO_VERSION);
    Test.assertEqual(frame[5], 87);
    decOpts[:offset] = 6;
    Test.assertEqual(frame.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 12);
    decOpts[:offset] = 20;
    Test.assertEqual(frame.decodeNumber(Lang.NUMBER_FORMAT_UINT16, decOpts).toNumber(), 14);
    Test.assertEqual(frame[22], 9);
    Test.assertEqual(frame[23], VoiceProto.END_STORAGE_FULL);
    logger.debug("SLVS 24B local link-status frame verified");
    return true;
}

(:test)
function testLaunchBlockGuards(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var cGlance = new VoiceController(VoiceProto.LAUNCH_FROM_GLANCE);
    Test.assert(cGlance.isTimeoutLaunch());
    Test.assertEqual(cGlance.launchBlockReason(), VoiceProto.LAUNCH_FROM_GLANCE);
    cGlance.toggleRecording();
    Test.assert(!cGlance.isRecording());
    cGlance.testStopTimer();

    var cComp = new VoiceController(VoiceProto.LAUNCH_FROM_COMPLICATION);
    Test.assert(cComp.isTimeoutLaunch());
    cComp.toggleRecording();
    Test.assert(!cComp.isRecording());
    cComp.testStopTimer();

    var cPost = new VoiceController(VoiceProto.LAUNCH_FROM_POST_INSTALL);
    Test.assert(cPost.isTimeoutLaunch());
    cPost.toggleRecording();
    Test.assert(!cPost.isRecording());
    cPost.testStopTimer();

    Storage.clearValues();
    logger.debug("Launch block guards (glance, complication, post-install) verified");
    return true;
}

(:test)
function testUnexpectedExitRecovery(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    // Simulate unclean crash/reboot: 3 unacked slabs + fgActive=1 persisted in K_FG_META
    var ring = new VoiceStorageRing();
    var chunk8k = new [8192]b;
    for (var i = 0; i < 3; i++) {
        Test.assert(ring.appendChunk(chunk8k, 16, 7, 1795651200, -420, i * 2000, i == 0));
    }
    ring.persistFgMeta(1, 7, 1795651200);

    // Fresh VoiceController open must report END_UNEXPECTED, reset fgActive=0, never auto-start, keep 3 slabs
    var ctrl = new VoiceController(VoiceProto.LAUNCH_OK);
    Test.assert(!ctrl.isRecording());
    Test.assertEqual(ctrl.lastEndReason(), VoiceProto.END_UNEXPECTED);
    Test.assertEqual(ctrl.pendingCount(), 3);
    var fgAfter = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7) as Array<Number>;
    Test.assertEqual(fgAfter[2], 0);
    ctrl.dismissLastEndReason();
    Test.assertEqual(ctrl.lastEndReason(), VoiceProto.END_NONE);
    ctrl.testStopTimer();

    Storage.clearValues();
    logger.debug("Unexpected exit recovery (END_UNEXPECTED, no auto-start, slabs preserved) verified");
    return true;
}

(:test)
function testCaptureActiveRequiresFirstChunk(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    var eng = new VoiceCaptureEngine();
    eng.testEnterRunning(1, -420);

    // Starting before first chunk: isRecording=true, isStarting=true, hasLiveAudio=false
    Test.assert(eng.isRecording());
    Test.assert(eng.isStarting());
    Test.assert(!eng.hasLiveAudio());

    // Empty 0-byte chunk must NOT flip hasLiveAudio to true
    eng.testCallbacks().onData(new [0]b);
    eng.tick(ring);
    Test.assert(!eng.hasLiveAudio());
    Test.assert(eng.isStarting());

    // Real non-empty audio chunk flips hasLiveAudio to true
    var realChunk = new [2048]b;
    eng.testCallbacks().onData(realChunk);
    eng.tick(ring);
    Test.assert(eng.hasLiveAudio());
    Test.assert(!eng.isStarting());

    Storage.clearValues();
    logger.debug("Active-means-audio (first non-empty chunk + 0-byte guard) verified");
    return true;
}

(:test)
function testInterruptionVsFailure(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var ring = new VoiceStorageRing();
    var eng = new VoiceCaptureEngine();

    // 1. CAPTURE_ERR_BACKGROUNDED -> temporary interruption: keeps active intent + isInterrupted=true
    eng.testEnterRunning(2, -420);
    eng.testCallbacks().onData(new [2048]b);
    eng.tick(ring);
    Test.assert(eng.hasLiveAudio());

    eng.testCallbacks().onError(Capture.CAPTURE_ERR_BACKGROUNDED);
    eng.tick(ring);
    Test.assert(eng.isRecording());
    Test.assert(eng.isInterrupted());
    Test.assert(!eng.hasLiveAudio());
    Test.assertEqual(ring.pendingCount(), 1); // Partial prefix flushed before interruption!

    // 2. CAPTURE_ERR_INTERNAL -> fatal failure: transitions to stopping -> idle with END_MIC_ERROR
    eng.testEnterRunning(3, -420);
    eng.testCallbacks().onError(Capture.CAPTURE_ERR_INTERNAL);
    eng.tick(ring);
    Test.assertEqual(eng.stopEndReason(), VoiceProto.END_MIC_ERROR);
    eng.testCallbacks().onComplete();
    eng.tick(ring);
    Test.assert(!eng.isRecording());

    Storage.clearValues();
    logger.debug("Interruption (CAPTURE_ERR_BACKGROUNDED) vs fatal failure (END_MIC_ERROR) verified");
    return true;
}

(:test)
function testBgServiceAndTransport(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var tx = new VoiceTransport();
    Test.assert(tx.isIdle());
    Test.assertEqual(tx.lastPhoneProtoVer(), -1);

    var bg = new VoiceBgService();
    Test.assertNotEqual(bg, null);

    var stats = System.getSystemStats();
    Test.assert(stats.freeMemory > 50000);
    logger.debug("VoiceTransport + VoiceBgService verified; freeMem=" + stats.freeMemory);
    return true;
}

(:test)
function testFaceKeyTzPointAndSnapshot(logger as Test.Logger) as Boolean {
    Storage.clearValues();

    // Verify parseAckTzPoint bounds & validation
    var tzOk = VoiceProto.parseAckTzPoint({ "a" => 7, "v" => 1, "z" => [3974, -10498] });
    Test.assert(tzOk != null);
    if (tzOk != null) {
        Test.assertEqual(tzOk[0], 3974);
        Test.assertEqual(tzOk[1], -10498);
    }
    Test.assert(VoiceProto.parseAckTzPoint({ "a" => 7, "z" => [99999, 0] }) == null);
    Test.assert(VoiceProto.parseAckTzPoint({ "a" => 7, "z" => [3974] }) == null);
    Test.assert(VoiceProto.parseAckTzPoint({ "a" => 7 }) == null);

    // Verify K_FACE (-4) writes on transitions only and survives empty-ring compaction
    var ring = new VoiceStorageRing();
    Test.assert(ring.writeFaceState(VoiceProto.PHASE_READY, VoiceProto.REASON_NONE, VoiceProto.END_NONE, 0));
    Test.assert(!ring.writeFaceState(VoiceProto.PHASE_READY, VoiceProto.REASON_NONE, VoiceProto.END_NONE, 0));
    Test.assert(ring.writeFaceState(VoiceProto.PHASE_ACTIVE, VoiceProto.REASON_NONE, VoiceProto.END_NONE, 1795800000));

    var face = VoiceProto.readIntArray(VoiceProto.K_FACE, 4);
    Test.assert(face != null);
    if (face != null) {
        Test.assertEqual(face[0], VoiceProto.PHASE_ACTIVE);
        Test.assertEqual(face[3], 1795800000);
    }

    // Seed K_SESSION_META (-5) with lastPhoneAckEpoch and tz point and verify snapshot reads them
    VoiceProto.writeIntArray(VoiceProto.K_SESSION_META, [
        VoiceProto.END_STORAGE_FULL, 1795800100, 1, 1, 1795800200, 3974, -10498
    ] as Array<Number>);
    var ctrl = new VoiceController(VoiceProto.LAUNCH_OK);
    ctrl.testStopTimer();
    var snap = ctrl.getSnapshot();
    Test.assertEqual(snap.phase, VoiceProto.PHASE_READY);
    Test.assertEqual(snap.reason, VoiceProto.REASON_NONE);
    Test.assertEqual(snap.lastEnd, VoiceProto.END_STORAGE_FULL);
    Test.assertEqual(snap.capSec, VoiceProto.HOLD_CAP_SEC);
    Test.assert(snap.phoneLinked);
    Test.assert(snap.lastPhoneEpoch == 1795800200);
    Test.assert(snap.tzLat100 == 3974);
    Test.assert(snap.tzLon100 == -10498);

    // Background wake without new ACK timestamp ("t") must NOT fabricate a newer lastPhoneEpoch
    ctrl.onBackgroundData({ "a" => 5, "s" => 0, "m" => 0, "w" => 2 });
    Test.assert(ctrl.lastPhoneEpoch() == 1795800200);
    // Background doorbell ACK with real "t" and "z" updates both
    ctrl.onBackgroundData({ "a" => 6, "t" => 1795800999, "z" => [3565, 13974] });
    Test.assert(ctrl.lastPhoneEpoch() == 1795800999);
    Test.assert(ctrl.tzLat100() == 3565);
    Test.assert(ctrl.tzLon100() == 13974);

    // Timeout launch sets REASON_TIMEOUT_LAUNCH and refuses start()
    var blocked = new VoiceController(VoiceProto.LAUNCH_FROM_GLANCE);
    blocked.testStopTimer();
    var bSnap = blocked.getSnapshot();
    Test.assertEqual(bSnap.reason, VoiceProto.REASON_TIMEOUT_LAUNCH);
    Test.assert(!blocked.start());

    Storage.clearValues();
    logger.debug("K_FACE (-4), tz point ACK, and VoiceSnapshot seam verified");
    return true;
}

(:test)
function testComplicationAndStaleFgCrashDrain(logger as Test.Logger) as Boolean {
    Storage.clearValues();
    var now = Time.now().value();

    // Alive foreground heartbeat (< 300s) -> fgAlive=true and ComplicationState=VALUE_ON
    Test.assert(VoiceBgService.isFgHeartbeatAlive(1, now - 30, now));
    Test.assert(!VoiceBgService.isFgHeartbeatAlive(0, now - 30, now));
    Test.assert(!VoiceBgService.isFgHeartbeatAlive(1, now - 301, now));
    Test.assert(!VoiceBgService.isFgHeartbeatAlive(1, 0, now));

    VoiceProto.writeIntArray(VoiceProto.K_FACE, [VoiceProto.PHASE_ACTIVE, VoiceProto.REASON_NONE, VoiceProto.END_NONE, now - 60] as Array<Number>);
    VoiceProto.writeIntArray(VoiceProto.K_FG_META, [10, 4, 1, VoiceProto.MODE_FG_BURST, 1, now - 60, now - 30] as Array<Number>);
    Test.assertEqual(ComplicationState.fromStorage(300), ComplicationState.VALUE_ON);

    // Stale foreground heartbeat after crash/reboot/kill -> fgAlive=false, complication flips to VALUE_UNKNOWN
    VoiceProto.writeIntArray(VoiceProto.K_FG_META, [10, 4, 1, VoiceProto.MODE_FG_BURST, 1, now - 600, now - 400] as Array<Number>);
    Test.assertEqual(ComplicationState.fromStorage(300), ComplicationState.VALUE_UNKNOWN);

    // Ready + END_STORAGE_FULL -> VALUE_ATTENTION; Ready + END_NONE -> VALUE_OFF
    VoiceProto.writeIntArray(VoiceProto.K_FACE, [VoiceProto.PHASE_READY, VoiceProto.REASON_STORAGE_FULL, VoiceProto.END_STORAGE_FULL, 0] as Array<Number>);
    Test.assertEqual(ComplicationState.fromStorage(0), ComplicationState.VALUE_ATTENTION);
    VoiceProto.writeIntArray(VoiceProto.K_FACE, [VoiceProto.PHASE_READY, VoiceProto.REASON_NONE, VoiceProto.END_NONE, 0] as Array<Number>);
    Test.assertEqual(ComplicationState.fromStorage(0), ComplicationState.VALUE_OFF);

    Storage.clearValues();
    logger.debug("ComplicationState.fromStorage and stale-FG crash-drain heartbeat guard verified");
    return true;
}
