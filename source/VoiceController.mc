// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Background;
import Toybox.Communications;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// Pure Foreground coordinator (NEVER compiled into the 64 KB Background VM!).
// Owns the single 250ms master Timer, Storage ring, Audio.Capture engine, FG half-duplex transport, and View state.
class VoiceController {
    private const QUIET_SETTLE_MS as Number = 500;
    private const QUIET_MAX_DRAIN_MS as Number = 120000;
    private const BACK_CONFIRM_MS as Number = 1500;

    private var _timeoutLaunch as Boolean;
    private var _ring as VoiceStorageRing;
    private var _capture as VoiceCaptureEngine;
    private var _tx as VoiceTransport;
    private var _timer as Timer.Timer;

    private var _mode as Number = VoiceProto.MODE_FG_BURST;
    private var _sessionStartMs as Number = 0;
    private var _batStartPct as Number = 0;
    private var _quietWaitStartMs as Number = 0;
    private var _backArmMs as Number = 0;
    private var _uiTick as Number = 0;
    private var _highPower as Boolean = true;
    private var _phoneRegistered as Boolean = false;
    private var _touchDisabled as Boolean = false;
    private var _telemEncOpts as { :offset as Number, :endianness as Lang.Endian };

    public function initialize(timeoutLaunch as Boolean) {
        _timeoutLaunch = timeoutLaunch;
        _telemEncOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
        _ring = new VoiceStorageRing();
        _capture = new VoiceCaptureEngine();
        _tx = new VoiceTransport();
        _timer = new Timer.Timer();

        // Restore persisted mode if present
        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg != null) {
            var savedMode = fg[3];
            if (savedMode >= 0 && savedMode <= 2) {
                _mode = savedMode;
            }
        }
        _tx.resetCursor(_ring.ackedSeq());
        _highPower = isDisplayHighPower();
        configureModeBindings();
        _ring.persistFgMeta(0, _mode, _capture.segId(), _capture.segEpoch());
        _timer.start(method(:onMasterTick), 250, true);

        var stats = System.getSystemStats();
        VoiceProto.vlog("SV FG start mode=" + _mode + " head=" + _ring.headSeq() + " ack=" + _ring.ackedSeq() + " free=" + stats.freeMemory);
    }

    public function createInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        return [new VoiceView(self), new VoiceInputDelegate(self)];
    }

    // View read-only accessors
    public function isTimeoutLaunch() as Boolean { return _timeoutLaunch; }
    public function mode() as Number { return _mode; }
    public function isRecording() as Boolean { return _capture.isRecording(); }
    public function captureState() as VoiceCaptureEngine.CapState { return _capture.getState(); }
    public function isStalled() as Boolean { return _capture.isStalled(); }
    public function isStorageFull() as Boolean { return _ring.isFull(); }
    public function segId() as Number { return _capture.segId(); }
    public function segsCompleted() as Number { return _capture.segsCompleted(); }
    public function pendingCount() as Number { return _ring.pendingCount(); }
    public function headSeq() as Number { return _ring.headSeq(); }
    public function ackedSeq() as Number { return _ring.ackedSeq(); }
    public function bgWakeCount() as Number { return _ring.bgWakeCount(); }
    public function isBackConfirmArmed() as Boolean {
        return (_backArmMs != 0) && ((System.getTimer() - _backArmMs) < BACK_CONFIRM_MS);
    }
    public function elapsedSec() as Number {
        if (!_capture.isRecording() || _sessionStartMs == 0) {
            return 0;
        }
        var dt = System.getTimer() - _sessionStartMs;
        return (dt > 0) ? (dt / 1000) : 0;
    }

    // Mode cycling (idle only) — zero USB reinstalls between Mode A / B / C bench runs
    public function cycleMode(delta as Number) as Void {
        if (_capture.isRecording()) {
            return;
        }
        _mode = (_mode + delta + 3) % 3;
        _tx.resetCursor(_ring.ackedSeq());
        configureModeBindings();
        _ring.persistFgMeta(0, _mode, _capture.segId(), _capture.segEpoch());
        VoiceProto.vlog("SV mode=" + VoiceProto.modeName(_mode));
        requestUiRefresh();
    }

    public function toggleRecording() as Void {
        if (_timeoutLaunch) {
            return;
        }
        if (_capture.isRecording()) {
            stopRecording();
        } else {
            startRecording();
        }
    }

    // Returns true if BACK press was consumed (double-press protection while recording)
    public function handleBackPress() as Boolean {
        if (!_capture.isRecording()) {
            return false; // Idle -> allow clean exit
        }
        var now = System.getTimer();
        if (_backArmMs != 0 && (now - _backArmMs) < BACK_CONFIRM_MS) {
            _backArmMs = 0;
            stopRecording();
            return false; // Second press within 1.5s -> exit cleanly
        }
        _backArmMs = now;
        requestUiRefresh();
        return true;
    }

    private function startRecording() as Void {
        _ring.syncBgAck();
        // If all prior audio is already delivered, reclaim old delivered .DAT/.IDX slots cleanly before starting!
        _ring.reclaimDeliveredOnIdle(_mode, _capture.segId(), _capture.segEpoch());
        if (_ring.isFull()) {
            requestUiRefresh();
            return;
        }
        _sessionStartMs = System.getTimer();
        _batStartPct = System.getSystemStats().battery.toNumber();
        _backArmMs = 0;
        _quietWaitStartMs = 0;

        // Next segment id persists monotonically across restarts via K_FG_META[4]
        var nextSeg = 1;
        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg != null && fg[4] >= 0) {
            nextSeg = fg[4] + 1;
        }

        configureModeBindings();
        setTouchEnabled(false); // Prevent sleeve/wet touches from killing capture

        if (_capture.startSession(nextSeg)) {
            _ring.persistFgMeta(1, _mode, _capture.segId(), _capture.segEpoch());
        } else {
            setTouchEnabled(true);
        }
        requestUiRefresh();
    }

    private function stopRecording() as Void {
        _capture.stopSession();
        _backArmMs = 0;
        setTouchEnabled(true);
        _ring.persistFgMeta(0, _mode, _capture.segId(), _capture.segEpoch());
        persistTelemetry();
        requestUiRefresh();
    }

    // Configure FG phone listener vs BG ServiceDelegate cleanly per selected mode
    private function configureModeBindings() as Void {
        if (_mode == VoiceProto.MODE_BG_DRAIN) {
            // Mode B: Foreground is 100% radio-silent! Leave phone messages strictly for VoiceBgService.
            if (_phoneRegistered) {
                try {
                    Communications.registerForPhoneAppMessages(null);
                    Communications.registerForPhoneAppMessageErrors(null);
                } catch (_) {}
                _phoneRegistered = false;
            }
            armBackgroundDrain();
        } else {
            // Mode A / Mode C: FG owns strict half-duplex BLE; BG temporal is DELETED while FG is open!
            disarmBackgroundTemporal();
            if (!_phoneRegistered) {
                try {
                    Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
                    Communications.registerForPhoneAppMessageErrors(method(:onPhoneMessageError));
                    _phoneRegistered = true;
                } catch (_) {}
            }
        }
    }

    private function armBackgroundDrain() as Void {
        try {
            Background.registerForTemporalEvent(new Time.Duration(300));
        } catch (_) {}
        try {
            Background.registerForPhoneAppMessageEvent();
        } catch (_) {}
    }

    private function disarmBackgroundTemporal() as Void {
        try {
            Background.deleteTemporalEvent();
        } catch (_) {}
    }

    private function setTouchEnabled(enabled as Boolean) as Void {
        if (enabled && !_touchDisabled) {
            return;
        }
        if (!enabled && _touchDisabled) {
            return;
        }
        try {
            if (WatchUi has :configureTouchEvents) {
                WatchUi.configureTouchEvents({ :enabled => enabled });
                _touchDisabled = !enabled;
            }
        } catch (_) {}
    }

    // Inbound FG phone message (Modes A & C only — strict half-duplex cumulative ACK)
    public function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        if (_mode == VoiceProto.MODE_BG_DRAIN) {
            return;
        }
        if (_tx.onPhoneMessage(msg, _ring)) {
            var fgActive = _capture.isRecording() ? 1 : 0;
            // Opportunistic zero-gap compaction right when burst drains to 0 (during ~2.5s window before next slab!)
            if (_ring.pendingCount() == 0 && _ring.needsCompaction()) {
                _ring.maybeCompactIfEmpty(fgActive, _mode, _capture.segId(), _capture.segEpoch());
            } else {
                _ring.persistFgMeta(fgActive, _mode, _capture.segId(), _capture.segEpoch());
            }
            requestUiRefresh();
        }
    }

    public function onPhoneMessageError(err as Communications.PhoneAppMessageError) as Void {
        _tx.onPhoneMsgError();
        VoiceProto.vlog("SV phoneMsgErr");
    }

    public function onBackgroundData(data as Application.PersistableType) as Void {
        _ring.syncBgAck();
        if (data instanceof Dictionary) {
            var d = data as Dictionary;
            var rawA = d["a"];
            if (rawA instanceof Number) {
                _ring.onAckConfirmed(rawA as Number);
            }
        }
        _tx.resetCursor(_ring.ackedSeq());
        requestUiRefresh();
    }

    public function onStorageChanged() as Void {
        _ring.syncBgAck();
        requestUiRefresh();
    }

    private function isDisplayHighPower() as Boolean {
        if (System has :getDisplayMode) {
            return System.getDisplayMode() == System.DISPLAY_MODE_HIGH_POWER;
        }
        return true; // MIP reflective displays stay readable without AMOLED burn-in modes
    }

    public function onDisplayModeChanged() as Void {
        _highPower = isDisplayHighPower();
        if (_highPower) {
            WatchUi.requestUpdate();
        }
    }

    // Single 250ms master timer driving ALL FG I/O, state transitions, BLE bursts, compaction, and <=1Hz UI redraws
    public function onMasterTick() as Void {
        var wasRecording = _capture.isRecording();
        var segSealed = _capture.tick(_ring, _mode);

        // If capture transitioned to IDLE (user stop or storage full), re-enable touch and persist state
        if (wasRecording && !_capture.isRecording()) {
            setTouchEnabled(true);
            _ring.persistFgMeta(0, _mode, _capture.segId(), _capture.segEpoch());
            persistTelemetry();
        }

        // Mode-specific transport scheduling
        if (_mode == VoiceProto.MODE_FG_BURST) {
            // Batch into K=8 bursts while recording; flush down to 0 when a segment seals or compaction is due (~5 min)
            var batchOnly = _capture.isRecording() && !segSealed && !_ring.needsCompaction();
            _tx.tick(_ring, batchOnly);
        } else if (_mode == VoiceProto.MODE_QUIET_BURST) {
            var capState = _capture.getState();
            if (capState == VoiceCaptureEngine.CAP_QUIET_WAIT) {
                var now = System.getTimer();
                if (_quietWaitStartMs == 0) {
                    _quietWaitStartMs = now;
                }
                var waited = now - _quietWaitStartMs;
                if (waited >= QUIET_SETTLE_MS) {
                    _tx.tick(_ring, false);
                    var done = (_ring.pendingCount() == 0 && _tx.isIdle()) ||
                               (!System.getDeviceSettings().phoneConnected) ||
                               (waited >= QUIET_MAX_DRAIN_MS);
                    if (done) {
                        _quietWaitStartMs = 0;
                        _capture.resumeAfterQuietDrain();
                        _ring.persistFgMeta(_capture.isRecording() ? 1 : 0, _mode, _capture.segId(), _capture.segEpoch());
                    }
                }
            } else if (capState == VoiceCaptureEngine.CAP_IDLE) {
                // Capture stopped: drain any remaining backlog cleanly
                _quietWaitStartMs = 0;
                _tx.tick(_ring, false);
            }
            // While CAP_RUNNING / CAP_STOPPING: ZERO BLE calls (0.00% overlap!)
        }
        // Mode B (MODE_BG_DRAIN): ZERO _tx calls in FG!

        // Periodic maintenance every 10s (40 ticks) + on segment seal
        _uiTick++;
        if (segSealed || (_uiTick % 40 == 0)) {
            if (_mode == VoiceProto.MODE_BG_DRAIN) {
                _ring.syncBgAck();
            }
            _ring.maybeCompactIfEmpty(_capture.isRecording() ? 1 : 0, _mode, _capture.segId(), _capture.segEpoch());
            if (segSealed) {
                persistTelemetry();
            }
        }

        // Gate AMOLED redraws to <=1 Hz AND strictly DISPLAY_MODE_HIGH_POWER
        if (_highPower && (_uiTick % 4 == 0)) {
            WatchUi.requestUpdate();
        }
    }

    private function persistTelemetry() as Void {
        var st = System.getSystemStats();
        var batPct = st.battery.toNumber();
        var freeKb = st.freeMemory / 1024;
        var sFlags = (st.charging ? 1 : 0) |
                     (_capture.isStalled() ? 2 : 0) |
                     (_ring.isFull() ? 4 : 0) |
                     (_capture.isRecording() ? 8 : 0);
        var telem = [
            _batStartPct,
            _capture.segsCompleted(),
            _ring.writeMaxMs(),
            _ring.writeCount(),
            _capture.isStalled() ? 1 : 0,
            _mode
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_TELEM, telem);

        // Queue compact 24B SLVT frame for Modes A/C (Mode B FG stays 100% radio-silent!)
        if (_mode != VoiceProto.MODE_BG_DRAIN) {
            var frame = VoiceProto.buildTelemFrame(
                _mode, batPct, _capture.segId(), freeKb,
                _ring.writeMaxMs(), _capture.droppedChunks(),
                _ring.bgWakeCount(), _ring.resetCount(),
                _tx.totalTxErr(), _ring.pendingCount(), sFlags,
                _telemEncOpts
            );
            _tx.queueTelem(frame);
        }
    }

    private function requestUiRefresh() as Void {
        if (_highPower) {
            WatchUi.requestUpdate();
        }
    }

    public function shutdown() as Void {
        _timer.stop();
        _capture.forceStopImmediate();
        // Flush any remaining buffered audio chunks safely before exit
        _capture.tick(_ring, _mode);
        _ring.flushSegmentTail(_mode, _capture.rateKhz(), _capture.segId(), _capture.segEpoch(), 0);
        setTouchEnabled(true);
        _ring.persistFgMeta(0, _mode, _capture.segId(), _capture.segEpoch());
        persistTelemetry();

        // Post-session background delivery for all modes when audio waits; zero battery drain when empty
        if (_ring.pendingCount() > 0) {
            armBackgroundDrain();
        } else {
            disarmBackgroundTemporal();
        }
        VoiceProto.vlog("SV FG stop pending=" + _ring.pendingCount() + " maxW=" + _ring.writeMaxMs() + "ms");
    }
}
