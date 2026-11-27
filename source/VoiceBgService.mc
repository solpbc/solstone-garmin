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

// Isolated 64 KB Background ServiceDelegate:
// - ZERO Timer usage (Timer has disableBackground = true)
// - Passive phoneConnected check -> exits in <15ms with zero radio if phone out of range
// - Callback-chained 22s burst drain (~180 KB per wake, 8 KB slabs) with iterative sync-callback trampoline
// - Delivers waiting slabs oldest-first after the watch app closes (never starts audio capture)
(:background)
class VoiceBgService extends System.ServiceDelegate {
    private const SLICE_BUDGET_MS as Number = 22000; // Leave 8s margin under 30s OS hard kill
    private const MAX_SLABS_PER_WAKE as Number = 24;

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
    private var _endingSlice as Boolean = false;
    private var _exited as Boolean = false;
    private var _ackEpoch as Number = 0;
    private var _ackTz as Array<Number>?;

    public function initialize() {
        ServiceDelegate.initialize();
    }

    public function onTemporalEvent() as Void {
        beginWake(false, -1, null);
    }

    public function onPhoneAppMessage(msg as Communications.PhoneAppMessage) as Void {
        var parsedAck = (msg != null) ? VoiceProto.parseAckSeq(msg.data) : -1;
        var parsedTz = (msg != null) ? VoiceProto.parseAckTzPoint(msg.data) : null;
        beginWake(true, parsedAck, parsedTz);
    }

    private function beginWake(fromDoorbell as Boolean, parsedAck as Number, parsedTz as Array<Number>?) as Void {
        _wakeStartMs = System.getTimer();
        _wakeEpoch = Time.now().value();
        _exited = false;
        _sentThisWake = 0;
        _ackEpoch = (fromDoorbell && parsedAck >= 0) ? _wakeEpoch : 0;
        _ackTz = parsedTz;

        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg == null) {
            Background.exit(null);
            return;
        }
        _headSeq = fg[0];
        _fgAckedSeq = fg[1];
        var fgActive = fg[2];

        var bg = VoiceProto.readIntArray(VoiceProto.K_BG_META, 5);
        if (bg != null) {
            _bgAckedSeq = bg[0];
            _lastSentSeq = bg[1];
            _wakeCount = bg[2];
            _prevWakeEpoch = bg[3];
            _lastErr = bg[4];
        }
        _wakeCount++;

        var ackChanged = false;
        if (parsedAck > _bgAckedSeq && parsedAck < _headSeq) {
            _bgAckedSeq = parsedAck;
            ackChanged = true;
        }

        // Foreground owns the radio while actively running; exit cleanly without touching BLE
        if (fgActive == 1) {
            if (ackChanged) {
                persistBgMeta(0);
            }
            Background.exit(null);
            return;
        }

        var confirmedAck = (_fgAckedSeq > _bgAckedSeq) ? _fgAckedSeq : _bgAckedSeq;

        if (fromDoorbell && parsedAck < 0 && _lastSentSeq > confirmedAck && _lastSentSeq < _headSeq && (_wakeEpoch - _prevWakeEpoch) <= 30) {
            _cursor = _lastSentSeq + 1;
        } else {
            _cursor = confirmedAck + 1;
        }

        if (_cursor >= _headSeq) {
            // Queue completely drained: stop 5-minute temporal wakes until next session leaves waiting audio
            try {
                Background.deleteTemporalEvent();
            } catch (_) {}
            if (ackChanged || _ackEpoch > 0 || _ackTz != null) {
                persistBgMeta(0);
                finishWake(0, 0);
            } else {
                Background.exit(null);
            }
            return;
        }

        if (!System.getDeviceSettings().phoneConnected) {
            if (ackChanged) {
                persistBgMeta(0);
            }
            Background.exit(null);
            return;
        }

        var stats = System.getSystemStats();
        VoiceProto.vlog("SV BG wake=" + _wakeCount + " door=" + fromDoorbell + " cur=" + _cursor + "/" + _headSeq + " free=" + stats.freeMemory);

        _endingSlice = false;
        driveLoop();
    }

    private function driveLoop() as Void {
        while (!_exited) {
            var elapsed = System.getTimer() - _wakeStartMs;
            if (_endingSlice || elapsed >= SLICE_BUDGET_MS || _sentThisWake >= MAX_SLABS_PER_WAKE || _cursor >= _headSeq) {
                var more = (_cursor < _headSeq) ? 1 : 0;
                finishWake(more, 0);
                return;
            }
            if (!System.getDeviceSettings().phoneConnected) {
                finishWake((_cursor < _headSeq) ? 1 : 0, 1);
                return;
            }

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
            _endingSlice = isLastOfSlice;

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
                return;
            }
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

    private function finishWake(more as Number, errCode as Number) as Void {
        if (_exited) {
            return;
        }
        _exited = true;
        persistBgMeta(errCode);
        var payload = {
            "a" => _bgAckedSeq,
            "s" => _sentThisWake,
            "m" => more,
            "w" => _wakeCount
        } as Dictionary<Application.PropertyKeyType, Application.PropertyValueType>;
        if (_ackEpoch > 0) {
            payload["t"] = _ackEpoch;
        }
        if (_ackTz != null) {
            payload["z"] = _ackTz as Array<Application.PropertyValueType>;
        }
        Background.exit(payload);
    }
}
