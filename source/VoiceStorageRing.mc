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
    private var _bgLastWakeEpoch as Number = 0;// Last BG wake UTC epoch (guards Mode B clearValues race)
    private var _bgWakeCount as Number = 0;
    private var _slabsSinceReset as Number = 0;
    private var _storageFull as Boolean = false;
    private var _writeMaxMs as Number = 0;
    private var _writeCount as Number = 0;
    private var _resetCount as Number = 0;

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

    public function persistFgMeta(fgActive as Number, modeId as Number, segId as Number, segEpoch as Number) as Void {
        var meta = [
            _headSeq,
            _fgAckedSeq,
            fgActive,
            modeId,
            segId,
            segEpoch,
            Time.now().value()
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_FG_META, meta);
    }

    // Stage an audio chunk outside onData() (called strictly from the 250ms master Timer)
    public function appendChunk(
        chunk as ByteArray,
        modeId as Number,
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
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
            return commitStagedSlab(modeId, rateKhz, segId, segEpoch, 0);
        }
        return true;
    }

    public function flushSegmentTail(
        modeId as Number,
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
        relMs as Number
    ) as Boolean {
        if (_chunks.size() == 0) {
            return true;
        }
        if (_stageRelMs == 0) {
            _stageRelMs = relMs;
        }
        return commitStagedSlab(modeId, rateKhz, segId, segEpoch, VoiceProto.FLAG_SEG_END);
    }

    private function commitStagedSlab(
        modeId as Number,
        rateKhz as Number,
        segId as Number,
        segEpoch as Number,
        extraFlags as Number
    ) as Boolean {
        // Honest full-storage check: never overwrite undelivered slabs
        if (pendingCount() >= VoiceProto.RING_CAP) {
            _storageFull = true;
            _chunks = [] as Array<ByteArray>;
            _chunkBytes = 0;
            return false;
        }

        // Zero-copy single-buffer slab assembly: reserve 24B header prefix, append chunks directly,
        // compute fastTag16 in place, and stamp SLV2 header into bytes 0..23 (halves transient peak RAM!)
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

        var flags = extraFlags | ((modeId & 0x07) << 5);
        if (_stageSegStart) {
            flags = flags | VoiceProto.FLAG_SEG_START;
            _stageSegStart = false;
        }
        var tag16 = VoiceProto.fastTag16(slab, VoiceProto.HDR_SIZE, plen);
        VoiceProto.writeHeaderInPlace(slab, flags, rateKhz, segId, _headSeq, segEpoch, _stageRelMs, plen, tag16, _encOpts);

        var slot = _headSeq % VoiceProto.RING_CAP;
        var t0 = System.getTimer();
        try {
            Storage.setValue(slot, slab);
        } catch (ex) {
            // If ALL prior slabs are already phone-ACKed (pendingCount == 0), reclaim fragmented .DAT and retry once!
            if (pendingCount() == 0) {
                forceCompactEmpty(1, modeId, segId, segEpoch);
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
        persistFgMeta(1, modeId, segId, segEpoch);
        return true;
    }

    // Read slab seq for FG transmit (returns null if missing/corrupt)
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
    // Avoids per-slab deleteValue() tombstones; when ring drains 100% empty after >=120 slabs (~1 MB),
    // clears .DAT cleanly in ~160ms and rewrites metadata cursors immediately.
    // In Mode B, also requires >35s since last BG wake so clearValues() can never race a live ServiceDelegate VM.
    public function maybeCompactIfEmpty(fgActive as Number, modeId as Number, segId as Number, segEpoch as Number) as Void {
        if (pendingCount() > 0 || _slabsSinceReset < 120) {
            return;
        }
        if (modeId == VoiceProto.MODE_BG_DRAIN) {
            var nowEpoch = Time.now().value();
            if (_bgLastWakeEpoch > 0 && (nowEpoch - _bgLastWakeEpoch) < 35) {
                return;
            }
        }
        forceCompactEmpty(fgActive, modeId, segId, segEpoch);
    }

    // Reclaim delivered .DAT/.IDX cleanly when pendingCount == 0 (safe on startSession or empty-ring fallback)
    public function reclaimDeliveredOnIdle(modeId as Number, segId as Number, segEpoch as Number) as Void {
        if (_headSeq > 0 && pendingCount() == 0) {
            forceCompactEmpty(0, modeId, segId, segEpoch);
            _storageFull = false;
        }
    }

    private function forceCompactEmpty(fgActive as Number, modeId as Number, segId as Number, segEpoch as Number) as Void {
        var bgMeta = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
        var telem = VoiceProto.readIntArray(VoiceProto.K_TELEM, 6);
        try {
            Storage.clearValues();
            _slabsSinceReset = 0;
            _resetCount++;
            persistFgMeta(fgActive, modeId, segId, segEpoch);
            if (bgMeta != null) {
                VoiceProto.writeIntArray(VoiceProto.K_BG_META, bgMeta);
            }
            if (telem != null) {
                VoiceProto.writeIntArray(VoiceProto.K_TELEM, telem);
            }
            VoiceProto.vlog("SV compacted empty ring at seq=" + _headSeq + " resets=" + _resetCount);
        } catch (_) {}
    }
}
