// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;

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
// Never invoked in Mode B (BG_DRAIN). Zero crossing messages (CIQQA-4866 safe), true app-level ACKs (CIQQA-4631 safe).
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
    private var _pendingTelem as ByteArray? = null;
    private var _sendingTelem as Boolean = false;

    public function initialize() {
    }

    public function queueTelem(frame as ByteArray) as Void {
        _pendingTelem = frame;
    }

    public function isIdle() as Boolean { return _state == TX_IDLE; }
    public function totalTxOk() as Number { return _totalTxOk; }
    public function totalTxErr() as Number { return _totalTxErr; }
    public function totalAcks() as Number { return _totalAcks; }
    public function phoneMsgErrs() as Number { return _phoneMsgErrs; }

    public function resetCursor(ackedSeq as Number) as Void {
        _nextSeq = ackedSeq + 1;
        _burstSent = 0;
        _state = TX_IDLE;
        _gen++;
    }

    public function onPhoneMsgError() as Void {
        _phoneMsgErrs++;
    }

    // Strict half-duplex inbound ACK handler (only expected in TX_WAIT_ACK). Returns true if ackedSeq advanced.
    public function onPhoneMessage(msg as Communications.PhoneAppMessage, ring as VoiceStorageRing) as Boolean {
        var ackSeq = VoiceProto.parseAckSeq(msg.data);
        if (ackSeq >= 0) {
            var advanced = ring.onAckConfirmed(ackSeq);
            _totalAcks++;
            _backoffMs = 2000;
            _backoffUntilMs = 0;
            if (_state == TX_WAIT_ACK) {
                _nextSeq = ring.ackedSeq() + 1;
                _burstSent = 0;
                _state = TX_IDLE;
            }
            return advanced;
        }
        return false;
    }

    public function onTxResult(gen as Number, ok as Boolean) as Void {
        if (gen != _gen || _state != TX_SENDING) {
            return;
        }
        if (_sendingTelem) {
            _sendingTelem = false;
            if (ok) {
                _pendingTelem = null;
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
                // Burst complete — yield the wire and wait for phone's single cumulative ACK
                _state = TX_WAIT_ACK;
                _ackWaitStartMs = System.getTimer();
            } else {
                // Return to TX_IDLE so the 250ms master Timer schedules the next slab (never chain inside callback!)
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
    // If requireFullBurst is true (Mode A during live capture), waits for >=K slabs (or quiet/sealed flush) to batch radio wakes.
    public function tick(ring as VoiceStorageRing, requireFullBurst as Boolean) as Void {
        var now = System.getTimer();

        if (_state == TX_SENDING) {
            if ((now - _txStartMs) >= TX_TIMEOUT_MS) {
                if (_sendingTelem) {
                    _sendingTelem = false;
                    _state = TX_IDLE;
                    _gen++;
                } else {
                    _totalTxErr++;
                    _gen++; // Ignore any late ghost listener
                    enterBackoff();
                }
            }
            return;
        }

        if (_state == TX_WAIT_ACK) {
            if ((now - _ackWaitStartMs) >= ACK_TIMEOUT_MS) {
                // Phone ACK lost or link dropped — rewind to last confirmed ACK + 1 and retry with backoff
                _nextSeq = ring.ackedSeq() + 1;
                enterBackoff();
            }
            return;
        }

        // TX_IDLE
        if (_backoffUntilMs != 0 && (now - _backoffUntilMs) < 0) {
            return;
        }
        _backoffUntilMs = 0;

        if (!System.getDeviceSettings().phoneConnected) {
            return;
        }

        // Send piggybacked 24-byte SLVT telemetry frame cleanly between bursts (strictly 1-in-flight, no ACK needed)
        var telem = _pendingTelem;
        if (telem != null && _burstSent == 0) {
            _gen++;
            var tGen = _gen;
            _sendingTelem = true;
            _state = TX_SENDING;
            _txStartMs = now;
            try {
                Communications.transmit(telem, {}, new VoiceTxListener(self.weak(), tGen));
            } catch (_) {
                if (_gen == tGen && _state == TX_SENDING) {
                    _sendingTelem = false;
                    _state = TX_IDLE;
                }
            }
            return;
        }

        var head = ring.headSeq();
        var minNext = ring.ackedSeq() + 1;
        if (_nextSeq < minNext) {
            _nextSeq = minNext;
        }
        if (_nextSeq >= head) {
            _burstSent = 0;
            return;
        }

        var waiting = head - _nextSeq;
        if (_burstSent == 0 && requireFullBurst && waiting < VoiceProto.BURST_SLABS) {
            return;
        }

        var slab = ring.readSlab(_nextSeq);
        if (slab == null) {
            // Corrupt/missing slot: advance past so queue never wedges
            _nextSeq++;
            return;
        }

        var isBurstEnd = (_burstSent + 1 >= VoiceProto.BURST_SLABS) || (_nextSeq + 1 >= head);
        if (isBurstEnd) {
            VoiceProto.patchHeaderFlags(slab, VoiceProto.FLAG_ACK_REQ);
            _burstTargetSeq = _nextSeq;
        } else {
            _burstTargetSeq = -1;
        }

        // Synchronous-callback guard (gimporter pattern): set state BEFORE calling transmit()
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
