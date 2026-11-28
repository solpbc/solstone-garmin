// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Cycle-free per-call ConnectionListener holding ONLY a WeakReference + generation guard
class VoiceTxListener extends Communications.ConnectionListener {
    private var _ownerWeak as WeakReference;
    private var _gen as Number;

    public function initialize(ownerWeak as WeakReference, gen as Number) {
        ConnectionListener.initialize();
        _ownerWeak = ownerWeak;
        _gen = gen;
    }

    public function onComplete() as Void {
        if (_ownerWeak.stillAlive()) {
            var owner = _ownerWeak.get() as VoiceTransport?;
            if (owner != null) {
                owner.onTxResult(_gen, true);
            }
        }
    }

    public function onError() as Void {
        if (_ownerWeak.stillAlive()) {
            var owner = _ownerWeak.get() as VoiceTransport?;
            if (owner != null) {
                owner.onTxResult(_gen, false);
            }
        }
    }
}

// Foreground strict half-duplex burst-then-ACK transport over Communications.transmit(ByteArray, {}, listener).
class VoiceTransport {
    public enum TxState {
        TX_IDLE,
        TX_SENDING,
        TX_WAIT_ACK
    }

    private const TX_TIMEOUT_MS as Number = 5000;
    private const ACK_TIMEOUT_MS as Number = 6000;

    private var _state as TxState = TX_IDLE;
    private var _gen as Number = 0;
    private var _txStartMs as Number = 0;
    private var _ackWaitStartMs as Number = 0;
    private var _backoffUntilMs as Number = 0;
    private var _backoffMs as Number = 2000;

    private var _nextSeq as Number = 0;
    private var _burstSent as Number = 0;
    private var _burstTargetSeq as Number = -1;
    private var _totalTxOk as Number = 0;
    private var _totalTxErr as Number = 0;
    private var _totalAcks as Number = 0;
    private var _phoneMsgErrs as Number = 0;
    private var _lastPhoneProtoVer as Number = -1;
    private var _lastAckEpoch as Number = 0;
    private var _lastTzLat100 as Number = VoiceProto.TZ_UNSET;
    private var _lastTzLon100 as Number = VoiceProto.TZ_UNSET;
    private var _pendingStatus as ByteArray? = null;
    private var _sendingStatus as Boolean = false;

    public function initialize() {
    }

    public function queueStatus(frame as ByteArray) as Void {
        _pendingStatus = frame;
    }

    public function isIdle() as Boolean { return _state == TX_IDLE; }
    public function totalTxOk() as Number { return _totalTxOk; }
    public function totalTxErr() as Number { return _totalTxErr; }
    public function totalAcks() as Number { return _totalAcks; }
    public function phoneMsgErrs() as Number { return _phoneMsgErrs; }
    public function lastPhoneProtoVer() as Number { return _lastPhoneProtoVer; }
    public function lastAckEpoch() as Number { return _lastAckEpoch; }
    public function lastTzLat100() as Number { return _lastTzLat100; }
    public function lastTzLon100() as Number { return _lastTzLon100; }

    public function resetCursor(ackedSeq as Number) as Void {
        _nextSeq = ackedSeq + 1;
        _burstSent = 0;
        _state = TX_IDLE;
        _gen++;
    }

    public function onPhoneMsgError() as Void {
        _phoneMsgErrs++;
    }

    // Strict half-duplex inbound ACK/hello handler. Returns true if ackedSeq, phone hello, version, or tz updated.
    public function onPhoneMessage(msg as Communications.PhoneAppMessage, ring as VoiceStorageRing) as Boolean {
        return handlePhoneData(msg.data, ring);
    }

    public function handlePhoneData(data as Object?, ring as VoiceStorageRing) as Boolean {
        var ver = VoiceProto.parseAckVersion(data);
        var metaChanged = false;
        if (ver >= 0) {
            _lastPhoneProtoVer = ver;
            _lastAckEpoch = Time.now().value();
            metaChanged = true;
        }
        var tz = VoiceProto.parseAckTzPoint(data);
        if (tz != null && (tz[0] != _lastTzLat100 || tz[1] != _lastTzLon100)) {
            _lastTzLat100 = tz[0];
            _lastTzLon100 = tz[1];
            metaChanged = true;
        }
        var ackSeq = VoiceProto.parseAckSeq(data);
        if (ackSeq >= 0) {
            ring.onAckConfirmed(ackSeq);
            _totalAcks++;
            _lastAckEpoch = Time.now().value();
            _backoffMs = 2000;
            _backoffUntilMs = 0;
            if (_state == TX_WAIT_ACK) {
                _nextSeq = ring.ackedSeq() + 1;
                _burstSent = 0;
                _state = TX_IDLE;
            }
            return true;
        }
        return metaChanged;
    }

    public function onTxResult(gen as Number, ok as Boolean) as Void {
        if (gen != _gen || _state != TX_SENDING) {
            return;
        }
        if (_sendingStatus) {
            _sendingStatus = false;
            if (ok) {
                _pendingStatus = null;
            }
            _state = TX_IDLE;
            return;
        }
        if (ok) {
            _totalTxOk++;
            _burstSent++;
            var sentSeq = _nextSeq;
            _nextSeq++;
            if (sentSeq == _burstTargetSeq) {
                _state = TX_WAIT_ACK;
                _ackWaitStartMs = System.getTimer();
            } else {
                _state = TX_IDLE;
            }
        } else {
            _totalTxErr++;
            enterBackoff();
        }
    }

    private function enterBackoff() as Void {
        _state = TX_IDLE;
        _burstSent = 0;
        _backoffUntilMs = System.getTimer() + _backoffMs;
        if (_backoffMs < 12000) {
            _backoffMs = _backoffMs * 2;
            if (_backoffMs > 12000) { _backoffMs = 12000; }
        }
    }

    // Called from 250ms master Timer ONLY (never inside onData() or onComplete()).
    public function tick(ring as VoiceStorageRing, requireFullBurst as Boolean) as Void {
        var now = System.getTimer();

        if (_state == TX_SENDING) {
            if ((now - _txStartMs) >= TX_TIMEOUT_MS) {
                if (_sendingStatus) {
                    _sendingStatus = false;
                    _state = TX_IDLE;
                    _gen++;
                } else {
                    _totalTxErr++;
                    _gen++;
                    enterBackoff();
                }
            }
            return;
        }

        if (_state == TX_WAIT_ACK) {
            if ((now - _ackWaitStartMs) >= ACK_TIMEOUT_MS) {
                _nextSeq = ring.ackedSeq() + 1;
                enterBackoff();
            }
            return;
        }

        if (_backoffUntilMs != 0 && (now - _backoffUntilMs) < 0) {
            return;
        }
        _backoffUntilMs = 0;

        if (!System.getDeviceSettings().phoneConnected) {
            return;
        }

        // Send 24-byte SLVS local link-status frame cleanly between bursts (strictly 1-in-flight)
        var statusFrame = _pendingStatus;
        if (statusFrame != null && _burstSent == 0) {
            _gen++;
            var sGen = _gen;
            _sendingStatus = true;
            _state = TX_SENDING;
            _txStartMs = now;
            try {
                Communications.transmit(statusFrame, {}, new VoiceTxListener(self.weak(), sGen));
            } catch (_) {
                if (_gen == sGen && _state == TX_SENDING) {
                    _sendingStatus = false;
                    _state = TX_IDLE;
                }
            }
            return;
        }

        var head = ring.headSeq();
        var confirmed = ring.ackedSeq();
        if (_nextSeq <= confirmed) {
            _nextSeq = confirmed + 1;
        }
        var remaining = head - _nextSeq;
        if (remaining <= 0) {
            _burstSent = 0;
            return;
        }

        if (_burstSent == 0 && requireFullBurst && remaining < VoiceProto.BURST_SLABS) {
            return;
        }

        if (_burstSent == 0) {
            var burstLen = (remaining < VoiceProto.BURST_SLABS) ? remaining : VoiceProto.BURST_SLABS;
            _burstTargetSeq = _nextSeq + burstLen - 1;
        }

        var slab = ring.readSlab(_nextSeq);
        while (slab == null && _nextSeq < head) {
            _nextSeq++;
            slab = ring.readSlab(_nextSeq);
        }
        if (slab == null) {
            _burstSent = 0;
            return;
        }

        var isBurstEnd = (_nextSeq >= _burstTargetSeq) || ((_nextSeq + 1) >= head);
        if (isBurstEnd) {
            _burstTargetSeq = _nextSeq;
            var patchFlags = VoiceProto.FLAG_ACK_REQ;
            if ((_nextSeq + 1) < head) {
                patchFlags = patchFlags | VoiceProto.FLAG_MORE_PENDING;
            }
            VoiceProto.patchHeaderFlags(slab, patchFlags);
        }

        _gen++;
        var callGen = _gen;
        _state = TX_SENDING;
        _txStartMs = now;
        try {
            Communications.transmit(slab, {}, new VoiceTxListener(self.weak(), callGen));
        } catch (_) {
            if (_gen == callGen && _state == TX_SENDING) {
                _totalTxErr++;
                enterBackoff();
            }
        }
    }
}
