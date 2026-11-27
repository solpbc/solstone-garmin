// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Foreground-only SPSC Storage ring writer with compaction-stall defense (OVERWRITE_AND_RESET)
class VoiceStorageRing {
    private var _encOpts as { :offset as Number, :endianness as Lang.Endian };
    private var _chunks as Array<ByteArray>;
    private var _chunkBytes as Number = 0;
    private var _stageSegStart as Boolean = false;
    private var _stageRelMs as Number = 0;

    private var _headSeq as Number = 0;        // Next monotonic slab seq to write (FG sole writer)
    private var _fgAckedSeq as Number = -1;    // Highest phone-ACKed seq confirmed in FG (persisted in K_FG_META[1])
    private var _ackedSeq as Number = -1;      // Effective confirmed ACK = max(_fgAckedSeq, bgAckedSeq)
    private var _bgLastWakeEpoch as Number = 0;
    private var _bgWakeCount as Number = 0;
    private var _slabsSinceReset as Number = 0;
    private var _storageFull as Boolean = false;
    private var _writeMaxMs as Number = 0;
    private var _writeCount as Number = 0;
    private var _resetCount as Number = 0;
    private var _faceInit as Boolean = false;
    private var _facePhase as Number = -1;
    private var _faceReason as Number = -1;
    private var _faceLastEnd as Number = -1;
    private var _faceStartEpoch as Number = -1;

    public function initialize() {
        _encOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
        _chunks = [] as Array<ByteArray>;
        restoreFromStorage();
    }

    public function restoreFromStorage() as Void {
        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg != null) {
            _headSeq = fg[0];
            _fgAckedSeq = fg[1];
            _ackedSeq = _fgAckedSeq;
        }
        syncBgAck();
        if (pendingCount() >= VoiceProto.RING_CAP) {
            _storageFull = true;
        }
    }

    public function syncBgAck() as Void {
        var bg = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
        if (bg != null) {
            if (bg[0] > _ackedSeq) {
                _ackedSeq = bg[0];
                _storageFull = false;
            }
            _bgWakeCount = bg[2];
            _bgLastWakeEpoch = bg[3];
        }
    }

    public function onAckConfirmed(seq as Number) as Boolean {
        var advanced = false;
        if (seq > _fgAckedSeq && seq < _headSeq) {
            _fgAckedSeq = seq;
            advanced = true;
        }
        if (seq > _ackedSeq && seq < _headSeq) {
            _ackedSeq = seq;
            _storageFull = false;
            advanced = true;
        }
        return advanced;
    }

    public function headSeq() as Number { return _headSeq; }
    public function ackedSeq() as Number { return _ackedSeq; }
    public function bgWakeCount() as Number { return _bgWakeCount; }
    public function pendingCount() as Number {
        var p = _headSeq - (_ackedSeq + 1);
        return (p > 0) ? p : 0;
    }
    public function isFull() as Boolean { return _storageFull; }
    public function needsCompaction() as Boolean { return _slabsSinceReset >= 120; }
    public function writeMaxMs() as Number { return _writeMaxMs; }
    public function writeCount() as Number { return _writeCount; }
    public function resetCount() as Number { return _resetCount; }

    public function persistFgMeta(fgActive as Number, segId as Number, segEpoch as Number) as Void {
        var meta = [
            _headSeq,
            _fgAckedSeq,
            fgActive,
            VoiceProto.MODE_FG_BURST,
            segId,
            segEpoch,
            Time.now().value()
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_FG_META, meta);
    }

    // Write tiny FG-only glance/complication key K_FACE (-4) ONLY when one of the 4 fields transitions
    public function writeFaceState(phase as Number, reason as Number, lastEnd as Number, startEpoch as Number) as Boolean {
        if (_faceInit && phase == _facePhase && reason == _faceReason && lastEnd == _faceLastEnd && startEpoch == _faceStartEpoch) {
            return false;
        }
        _faceInit = true;
        _facePhase = phase;
        _faceReason = reason;
        _faceLastEnd = lastEnd;
        _faceStartEpoch = startEpoch;
        var face = [phase, reason, lastEnd, startEpoch] as Array<Number>;
        return VoiceProto.writeIntArray(VoiceProto.K_FACE, face);
    }

    // Stage an audio chunk outside onData() (called strictly from the 250ms master Timer)
    public function appendChunk(
        chunk as ByteArray,
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
        tzOffsetMin as Number,
        relMs as Number,
        isSegStart as Boolean
    ) as Boolean {
        if (_storageFull) {
            return false;
        }
        if (_chunks.size() == 0) {
            _stageSegStart = isSegStart;
            _stageRelMs = relMs;
        } else if (isSegStart) {
            _stageSegStart = true;
        }
        _chunks.add(chunk);
        _chunkBytes += chunk.size();

        if (_chunkBytes >= VoiceProto.SLAB_TARGET_BYTES) {
            return commitStagedSlab(rateKhz, segId, segEpoch, tzOffsetMin, 0);
        }
        return true;
    }

    public function flushSegmentTail(
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
        tzOffsetMin as Number,
        relMs as Number,
        isPartial as Boolean
    ) as Boolean {
        if (_chunks.size() == 0) {
            return true;
        }
        if (_stageRelMs == 0) {
            _stageRelMs = relMs;
        }
        var extraFlags = VoiceProto.FLAG_SEG_END;
        if (isPartial) {
            extraFlags = extraFlags | VoiceProto.FLAG_SEG_PARTIAL;
        }
        return commitStagedSlab(rateKhz, segId, segEpoch, tzOffsetMin, extraFlags);
    }

    private function commitStagedSlab(
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
        tzOffsetMin as Number,
        extraFlags as Number
    ) as Boolean {
        // Honest full-storage check: never overwrite undelivered slabs
        if (pendingCount() >= VoiceProto.RING_CAP) {
            _storageFull = true;
            _chunks = [] as Array<ByteArray>;
            _chunkBytes = 0;
            return false;
        }

        // Single-buffer slab assembly: reserve 28B SLV3 header, append chunks, compute fastTag16, stamp header
        var slab = new [VoiceProto.HDR_SIZE]b;
        var n = _chunks.size();
        for (var i = 0; i < n; i++) {
            slab.addAll(_chunks[i]);
        }
        _chunks = [] as Array<ByteArray>;
        _chunkBytes = 0;

        var plen = slab.size() - VoiceProto.HDR_SIZE;
        if (plen <= 0) {
            return true;
        }

        var flags = extraFlags;
        if (_stageSegStart) {
            flags = flags | VoiceProto.FLAG_SEG_START;
            _stageSegStart = false;
        }
        var tag16 = VoiceProto.fastTag16(slab, VoiceProto.HDR_SIZE, plen);
        VoiceProto.writeHeaderInPlace(
            slab, flags, rateKhz, segId, _headSeq, segEpoch, tzOffsetMin, _stageRelMs, plen, tag16, _encOpts
        );

        var slot = _headSeq % VoiceProto.RING_CAP;
        var t0 = System.getTimer();
        try {
            Storage.setValue(slot, slab);
        } catch (ex) {
            if (pendingCount() == 0) {
                forceCompactEmpty(1, segId, segEpoch);
                try {
                    Storage.setValue(slot, slab);
                } catch (ex2) {
                    _storageFull = true;
                    VoiceProto.vlog("SV storage full after compact seq=" + _headSeq + " err=" + ex2.getErrorMessage());
                    return false;
                }
            } else {
                // Never clear or overwrite undelivered slabs
                _storageFull = true;
                VoiceProto.vlog("SV storage full seq=" + _headSeq + " err=" + ex.getErrorMessage());
                return false;
            }
        }
        var dt = System.getTimer() - t0;
        if (dt > _writeMaxMs) {
            _writeMaxMs = dt;
        }
        _writeCount++;
        _headSeq++;
        _slabsSinceReset++;
        persistFgMeta(1, segId, segEpoch);
        return true;
    }

    public function readSlab(seq as Number) as ByteArray? {
        if (seq < 0 || seq >= _headSeq) {
            return null;
        }
        try {
            var v = Storage.getValue(seq % VoiceProto.RING_CAP);
            if (v instanceof ByteArray) {
                return v as ByteArray;
            }
        } catch (_) {}
        return null;
    }

    // Compaction-stall defense (OVERWRITE_AND_RESET):
    // When ring drains 100% empty after >=120 slabs (~1 MB), clears Storage cleanly and rewrites metadata cursors.
    public function maybeCompactIfEmpty(fgActive as Number, segId as Number, segEpoch as Number) as Void {
        if (pendingCount() > 0 || _slabsSinceReset < 120) {
            return;
        }
        if (_bgLastWakeEpoch > 0 && (Time.now().value() - _bgLastWakeEpoch) < 35) {
            return;
        }
        forceCompactEmpty(fgActive, segId, segEpoch);
    }

    public function reclaimDeliveredOnIdle(segId as Number, segEpoch as Number) as Void {
        if (_headSeq > 0 && pendingCount() == 0) {
            forceCompactEmpty(0, segId, segEpoch);
            _storageFull = false;
        }
    }

    private function forceCompactEmpty(fgActive as Number, segId as Number, segEpoch as Number) as Void {
        var bgMeta = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
        var health = VoiceProto.readIntArray(VoiceProto.K_HEALTH, 6);
        var face = VoiceProto.readIntArray(VoiceProto.K_FACE, 4);
        var sessMeta = VoiceProto.readIntArray(VoiceProto.K_SESSION_META, 7);
        try {
            Storage.clearValues();
            _slabsSinceReset = 0;
            _resetCount++;
            persistFgMeta(fgActive, segId, segEpoch);
            if (bgMeta != null) {
                VoiceProto.writeIntArray(VoiceProto.K_BG_META, bgMeta);
            }
            if (health != null) {
                VoiceProto.writeIntArray(VoiceProto.K_HEALTH, health);
            }
            if (face != null) {
                VoiceProto.writeIntArray(VoiceProto.K_FACE, face);
            }
            if (sessMeta != null) {
                VoiceProto.writeIntArray(VoiceProto.K_SESSION_META, sessMeta);
            }
            VoiceProto.vlog("SV compacted empty ring at seq=" + _headSeq + " resets=" + _resetCount);
        } catch (_) {}
    }
}
