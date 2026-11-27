// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Cycle-free background ConnectionListener holding ONLY a WeakReference + generation guard
(:background)
class VoiceBgTxListener extends Communications.ConnectionListener {
    private var _ownerWeak as WeakReference;
    private var _gen as Number;

    public function initialize(ownerWeak as WeakReference, gen as Number) {
        ConnectionListener.initialize();
        _ownerWeak = ownerWeak;
        _gen = gen;
    }

    public function onComplete() as Void {
        if (_ownerWeak.stillAlive()) {
            var owner = _ownerWeak.get() as VoiceBgService?;
            if (owner != null) {
                owner.onTxResult(_gen, true);
            }
        }
    }

    public function onError() as Void {
        if (_ownerWeak.stillAlive()) {
            var owner = _ownerWeak.get() as VoiceBgService?;
            if (owner != null) {
                owner.onTxResult(_gen, false);
            }
        }
    }
}

// Ultra-lean isolated 64 KB Background ServiceDelegate:
// - ZERO Timer usage (Timer has disableBackground = true in SDK 9.3.0)
// - Passive phoneConnected check -> exits in <15ms with zero radio if phone out of range
// - Callback-chained 22s burst drain (~180 KB per wake, 8 KB slabs) with iterative sync-callback trampoline
// - Powers Mode B (two-process split) and post-session background delivery for Modes A/C
(:background)
class VoiceBgService extends System.ServiceDelegate {
    private const SLICE_BUDGET_MS as Number = 22000; // Leave 8s margin under 30s OS hard kill
    private const MAX_SLABS_PER_WAKE as Number = 24; // ~192 KB max per slice

    private var _wakeStartMs as Number = 0;
    private var _wakeEpoch as Number = 0;
    private var _headSeq as Number = 0;
    private var _fgAckedSeq as Number = -1;
    private var _bgAckedSeq as Number = -1;
    private var _lastSentSeq as Number = -1;
    private var _wakeCount as Number = 0;
    private var _prevWakeEpoch as Number = 0;
    private var _lastErr as Number = 0;

    private var _cursor as Number = 0;
    private var _sentThisWake as Number = 0;
    private var _gen as Number = 0;
    private var _inDispatch as Boolean = false;
    private var _syncCompleted as Boolean = false;
    private var _exited as Boolean = false;

    public function initialize() {
        ServiceDelegate.initialize();
    }

    // 5-minute passive range check & burst trigger
    public function onTemporalEvent() as Void {
        beginWake(false, -1);
    }

    // Phone wake doorbell (Mode B chaining and post-session drain).
    // Tolerates Android Connect IQ quirk where msg.data can arrive null (forum 424474).
    public function onPhoneAppMessage(msg as Communications.PhoneAppMessage) as Void {
        var parsedAck = (msg != null) ? VoiceProto.parseAckSeq(msg.data) : -1;
        beginWake(true, parsedAck);
    }

    private function beginWake(fromDoorbell as Boolean, parsedAck as Number) as Void {
        _wakeStartMs = System.getTimer();
        _wakeEpoch = Time.now().value();
        _exited = false;
        _sentThisWake = 0;

        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg == null) {
            Background.exit(null);
            return;
        }
        _headSeq = fg[0];
        _fgAckedSeq = fg[1];
        var fgActive = fg[2];
        var fgMode = fg[3];

        // Load BG sole-writer state: [bgAckedSeq, lastSentSeq, wakeCount, lastWakeEpoch, lastErr]
        var bg = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
        if (bg != null) {
            _bgAckedSeq = bg[0];
            _lastSentSeq = bg[1];
            _wakeCount = bg[2];
            _prevWakeEpoch = bg[3];
            _lastErr = bg[4];
        }
        _wakeCount++;

        // Apply any explicit phone cumulative ACK carried by doorbell
        var ackChanged = false;
        if (parsedAck > _bgAckedSeq && parsedAck < _headSeq) {
            _bgAckedSeq = parsedAck;
            ackChanged = true;
        }

        // If FG owns the radio (Modes A or C while actively running), exit silently without touching BLE
        if (fgActive == 1 && fgMode != VoiceProto.MODE_BG_DRAIN) {
            if (ackChanged) {
                persistBgMeta(0);
            }
            Background.exit(null);
            return;
        }

        var confirmedAck = (_fgAckedSeq > _bgAckedSeq) ? _fgAckedSeq : _bgAckedSeq;

        // Pick burst start cursor:
        // - Explicit ACK or temporal wake: start strictly at confirmedAck + 1 (at-least-once safe)
        // - Null-data doorbell within 30s of prior slice: advance past _lastSentSeq so Android null-payload quirk never loops
        if (fromDoorbell && parsedAck < 0 && _lastSentSeq > confirmedAck && _lastSentSeq < _headSeq && (_wakeEpoch - _prevWakeEpoch) <= 30) {
            _cursor = _lastSentSeq + 1;
        } else {
            _cursor = confirmedAck + 1;
        }

        // Nothing waiting? Exit immediately (<15ms, zero radio)
        if (_cursor >= _headSeq) {
            if (ackChanged) {
                persistBgMeta(0);
                finishWake(0, 0);
            } else {
                Background.exit(null);
            }
            return;
        }

        // Passive range check — out of range means zero BLE transmit calls, exit in <15ms
        if (!System.getDeviceSettings().phoneConnected) {
            if (ackChanged) {
                persistBgMeta(0);
            }
            Background.exit(null);
            return;
        }

        var stats = System.getSystemStats();
        VoiceProto.vlog("SV BG wake=" + _wakeCount + " door=" + fromDoorbell + " cur=" + _cursor + "/" + _headSeq + " free=" + stats.freeMemory);

        // Start callback-chained burst loop
        driveLoop();
    }

    // Iterative trampoline handles both async BLE callbacks AND sync simulator callbacks in O(1) stack
    private function driveLoop() as Void {
        while (!_exited) {
            var elapsed = System.getTimer() - _wakeStartMs;
            if (elapsed >= SLICE_BUDGET_MS || _sentThisWake >= MAX_SLABS_PER_WAKE || _cursor >= _headSeq) {
                var more = (_cursor < _headSeq) ? 1 : 0;
                finishWake(more, 0);
                return;
            }
            if (!System.getDeviceSettings().phoneConnected) {
                finishWake((_cursor < _headSeq) ? 1 : 0, 1);
                return;
            }

            // Read 8 KB slab from Storage (skip any missing/corrupt slot cleanly)
            var slab = null;
            while (_cursor < _headSeq) {
                try {
                    var raw = Storage.getValue(_cursor % VoiceProto.RING_CAP);
                    if (raw instanceof ByteArray) {
                        slab = raw as ByteArray;
                        break;
                    }
                } catch (_) {}
                _cursor++;
            }
            if (slab == null) {
                finishWake(0, 0);
                return;
            }

            var moreAfter = (_cursor + 1) < _headSeq;
            var isLastOfSlice =
                ((_sentThisWake + 1) >= MAX_SLABS_PER_WAKE) ||
                (!moreAfter) ||
                ((System.getTimer() - _wakeStartMs) >= (SLICE_BUDGET_MS - 1500));

            var patchFlags = VoiceProto.FLAG_BG_ORIGIN;
            if (isLastOfSlice) {
                patchFlags = patchFlags | VoiceProto.FLAG_ACK_REQ;
                if (moreAfter) {
                    patchFlags = patchFlags | VoiceProto.FLAG_MORE_PENDING;
                }
            }
            VoiceProto.patchHeaderFlags(slab, patchFlags);

            _gen++;
            var callGen = _gen;
            _inDispatch = true;
            _syncCompleted = false;
            try {
                Communications.transmit(slab, {}, new VoiceBgTxListener(self.weak(), callGen));
            } catch (_) {
                _inDispatch = false;
                finishWake((_cursor < _headSeq) ? 1 : 0, 2);
                return;
            }
            _inDispatch = false;

            if (!_syncCompleted) {
                // Async callback pending — yield VM cleanly until VoiceBgTxListener fires
                return;
            }
            // Synchronous callback fired inline; continue iterative loop
        }
    }

    public function onTxResult(gen as Number, ok as Boolean) as Void {
        if (_exited || gen != _gen) {
            return;
        }
        if (ok) {
            _lastSentSeq = _cursor;
            _cursor++;
            _sentThisWake++;
            if (_inDispatch) {
                _syncCompleted = true;
            } else {
                driveLoop();
            }
        } else {
            finishWake((_cursor < _headSeq) ? 1 : 0, 3);
        }
    }

    private function persistBgMeta(errCode as Number) as Void {
        _lastErr = errCode;
        var meta = [
            _bgAckedSeq,
            _lastSentSeq,
            _wakeCount,
            _wakeEpoch,
            _lastErr
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_BG_META, meta);
    }

    private function finishWake(morePending as Number, errCode as Number) as Void {
        if (_exited) {
            return;
        }
        _exited = true;
        persistBgMeta(errCode);
        var payload = {
            "a" => _bgAckedSeq,
            "s" => _lastSentSeq,
            "m" => morePending,
            "n" => _sentThisWake
        } as Dictionary<String, Number>;
        Background.exit(payload as Application.PersistableType);
    }
}
