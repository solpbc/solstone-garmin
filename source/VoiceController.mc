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

// Pure Foreground coordinator (never compiled into the 64 KB Background VM).
// Owns the single 250ms master Timer, Storage ring, Audio.Capture engine, FG half-duplex transport,
// session end-reason persistence, and read-only view state seam.
class VoiceController {
    private const BACK_CONFIRM_MS as Number = 1500;
    private const COMPANION_LINK_URL as String = "https://go.solstone.app/garmin";

    private var _launchBlockReason as Number;
    private var _ring as VoiceStorageRing;
    private var _capture as VoiceCaptureEngine;
    private var _tx as VoiceTransport;
    private var _timer as Timer.Timer;

    private var _sessionStartMs as Number = 0;
    private var _sessionStartEpoch as Number = 0;
    private var _stopping as Boolean = false;
    private var _batStartPct as Number = 0;
    private var _backArmMs as Number = 0;
    private var _uiTick as Number = 0;
    private var _highPower as Boolean = true;
    private var _phoneRegistered as Boolean = false;
    private var _touchDisabled as Boolean = false;
    private var _lastEndReason as Number = VoiceProto.END_NONE;
    private var _lastEndEpoch as Number = 0;
    private var _phoneProtoVer as Number = -1;
    private var _phoneEverAcked as Number = 0;
    private var _lastPhoneAckEpoch as Number = 0;
    private var _tzLat100 as Number = VoiceProto.TZ_UNSET;
    private var _tzLon100 as Number = VoiceProto.TZ_UNSET;
    private var _statusEncOpts as { :offset as Number, :endianness as Lang.Endian };

    public function initialize(launchBlockReason as Number) {
        _launchBlockReason = launchBlockReason;
        _statusEncOpts = { :offset => 0, :endianness => Lang.ENDIAN_BIG };
        _ring = new VoiceStorageRing();
        _capture = new VoiceCaptureEngine();
        _tx = new VoiceTransport();
        _timer = new Timer.Timer();

        restoreSessionMeta();

        // Detect unclean previous exit (crash, watch reboot, OS eviction, palm cover, firmware update).
        // Record END_UNEXPECTED and reset fgActive=0 without ever auto-restarting audio capture.
        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        var lastSegId = 0;
        var lastSegEpoch = 0;
        if (fg != null) {
            lastSegId = fg[4];
            lastSegEpoch = fg[5];
            if (fg[2] == 1) {
                _lastEndReason = VoiceProto.END_UNEXPECTED;
                _lastEndEpoch = (fg[6] > 0) ? fg[6] : Time.now().value();
                persistSessionMeta();
            }
        }
        if (_ring.ackedSeq() >= 0 && _phoneEverAcked == 0) {
            _phoneEverAcked = 1;
            persistSessionMeta();
        }

        _tx.resetCursor(_ring.ackedSeq());
        _highPower = isDisplayHighPower();
        configureForegroundBindings();
        _ring.persistFgMeta(0, lastSegId, lastSegEpoch);
        syncFaceState();
        queueLocalStatusFrame();
        _timer.start(method(:onMasterTick), 250, true);

        var stats = System.getSystemStats();
        VoiceProto.vlog("SV FG start head=" + _ring.headSeq() + " ack=" + _ring.ackedSeq() + " end=" + _lastEndReason + " free=" + stats.freeMemory);
    }

    public function createInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new VoiceView(self);
        return [view, new VoiceInputDelegate(self, view)];
    }

    // Single read-only view snapshot for WatchUi layer (never exposes Capture, Storage, or Communications)
    public function getSnapshot() as VoiceSnapshot {
        var pending = _ring.pendingCount();
        var heldSec = (pending * 9050) / 3700;
        var startEp = (_sessionStartEpoch > 0 && _capture.isRecording()) ? _sessionStartEpoch : null;
        var phoneEp = (_lastPhoneAckEpoch > 0) ? _lastPhoneAckEpoch : null;
        var tzLat = (_tzLat100 != VoiceProto.TZ_UNSET) ? _tzLat100 : null;
        var tzLon = (_tzLon100 != VoiceProto.TZ_UNSET) ? _tzLon100 : null;
        return new VoiceSnapshot(
            currentPhase(),
            currentReason(),
            _lastEndReason,
            _lastEndEpoch,
            startEp,
            heldSec,
            VoiceProto.HOLD_CAP_SEC,
            pending,
            System.getDeviceSettings().phoneConnected,
            isPhoneLinked(),
            phoneEp,
            tzLat,
            tzLon,
            _touchDisabled,
            _capture.isInterrupted(),
            _launchBlockReason
        );
    }

    public function currentPhase() as Number {
        if (_stopping) {
            return VoiceProto.PHASE_STOPPING;
        }
        if (_capture.hasLiveAudio()) {
            return VoiceProto.PHASE_ACTIVE;
        }
        if (_capture.isStarting()) {
            return VoiceProto.PHASE_STARTING;
        }
        if (_capture.isRecording()) {
            return _capture.sessionHasAudio() ? VoiceProto.PHASE_ACTIVE : VoiceProto.PHASE_STARTING;
        }
        return VoiceProto.PHASE_READY;
    }

    // Worst-first single attention reason
    public function currentReason() as Number {
        if (_launchBlockReason != VoiceProto.LAUNCH_OK) {
            return VoiceProto.REASON_TIMEOUT_LAUNCH;
        }
        if (_lastEndReason == VoiceProto.END_MIC_DENIED && !_capture.isRecording()) {
            return VoiceProto.REASON_MIC_PERMISSION;
        }
        if (_ring.isFull()) {
            return VoiceProto.REASON_STORAGE_FULL;
        }
        if (_capture.isStalled()) {
            return VoiceProto.REASON_MIC_STALLED;
        }
        var mm = phoneProtoMismatch();
        if (mm > 0) {
            return VoiceProto.REASON_WATCH_TOO_OLD;
        }
        if (mm < 0) {
            return VoiceProto.REASON_PHONE_TOO_OLD;
        }
        return VoiceProto.REASON_NONE;
    }

    public function lastPhoneEpoch() as Number? { return (_lastPhoneAckEpoch > 0) ? _lastPhoneAckEpoch : null; }
    public function tzLat100() as Number? { return (_tzLat100 != VoiceProto.TZ_UNSET) ? _tzLat100 : null; }
    public function tzLon100() as Number? { return (_tzLon100 != VoiceProto.TZ_UNSET) ? _tzLon100 : null; }

    // Delegate actions for WatchUi layer
    public function start() as Boolean {
        if (_launchBlockReason != VoiceProto.LAUNCH_OK || _capture.isRecording()) {
            return false;
        }
        return startRecording();
    }

    public function stop() as Void {
        if (_capture.isRecording()) {
            stopRecording(VoiceProto.END_USER_STOP);
        }
    }

    public function setTouchLock(locked as Boolean) as Void {
        setTouchEnabled(!locked);
        requestUiRefresh();
    }

    public function toggleTouchLock() as Boolean {
        setTouchEnabled(_touchDisabled);
        requestUiRefresh();
        return _touchDisabled;
    }

    // Read-only state seam for WatchUi View / Glance / Complication layers
    public function isTimeoutLaunch() as Boolean { return _launchBlockReason != VoiceProto.LAUNCH_OK; }
    public function launchBlockReason() as Number { return _launchBlockReason; }
    public function isRecording() as Boolean { return _capture.isRecording(); }
    public function hasLiveAudio() as Boolean { return _capture.hasLiveAudio(); }
    public function isStarting() as Boolean { return _capture.isStarting(); }
    public function isInterrupted() as Boolean { return _capture.isInterrupted(); }
    public function isStalled() as Boolean { return _capture.isStalled(); }
    public function isStorageFull() as Boolean { return _ring.isFull(); }
    public function lastCaptureError() as Number { return _capture.lastError(); }
    public function lastEndReason() as Number { return _lastEndReason; }
    public function lastEndEpoch() as Number { return _lastEndEpoch; }
    public function segId() as Number { return _capture.segId(); }
    public function segsCompleted() as Number { return _capture.segsCompleted(); }
    public function pendingCount() as Number { return _ring.pendingCount(); }
    public function headSeq() as Number { return _ring.headSeq(); }
    public function ackedSeq() as Number { return _ring.ackedSeq(); }
    public function bgWakeCount() as Number { return _ring.bgWakeCount(); }
    public function isTouchLocked() as Boolean { return _touchDisabled; }
    public function phoneConnected() as Boolean { return System.getDeviceSettings().phoneConnected; }
    public function isPhoneLinked() as Boolean { return (_phoneEverAcked != 0) || (_ring.ackedSeq() >= 0); }

    // Returns -1 if phone is older than watch protocol, +1 if watch is older than phone, 0 if matching or unknown
    public function phoneProtoMismatch() as Number {
        if (_phoneProtoVer < 0) {
            return 0;
        }
        if (_phoneProtoVer < VoiceProto.PROTO_VERSION) {
            return -1;
        }
        if (_phoneProtoVer > VoiceProto.PROTO_VERSION) {
            return 1;
        }
        return 0;
    }

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

    public function dismissLastEndReason() as Void {
        if (_lastEndReason != VoiceProto.END_NONE) {
            _lastEndReason = VoiceProto.END_NONE;
            _lastEndEpoch = 0;
            persistSessionMeta();
            syncFaceState();
            requestUiRefresh();
        }
    }

    // Owner-initiated one-time companion activation link (never called automatically in background)
    public function requestLinkPhone() as Boolean {
        if (!System.getDeviceSettings().phoneConnected) {
            return false;
        }
        try {
            Communications.openWebPage(COMPANION_LINK_URL, null, null);
            return true;
        } catch (_) {}
        return false;
    }

    public function toggleRecording() as Void {
        if (_launchBlockReason != VoiceProto.LAUNCH_OK) {
            return;
        }
        if (_capture.isRecording()) {
            stopRecording(VoiceProto.END_USER_STOP);
        } else {
            startRecording();
        }
    }

    // Returns true if BACK press was consumed (double-press guard while recording)
    public function handleBackPress() as Boolean {
        if (!_capture.isRecording()) {
            return false;
        }
        var now = System.getTimer();
        if (_backArmMs != 0 && (now - _backArmMs) < BACK_CONFIRM_MS) {
            _backArmMs = 0;
            stopRecording(VoiceProto.END_USER_STOP);
            return false;
        }
        _backArmMs = now;
        requestUiRefresh();
        return true;
    }

    public function onAppInactive() as Void {
        _capture.onAppInactive();
        requestUiRefresh();
    }

    public function onAppActive() as Void {
        _capture.onAppActive();
        requestUiRefresh();
    }

    private function startRecording() as Boolean {
        _ring.syncBgAck();
        _ring.reclaimDeliveredOnIdle(_capture.segId(), _capture.segEpoch());
        if (_ring.isFull()) {
            recordEndReason(VoiceProto.END_STORAGE_FULL);
            syncFaceState();
            requestUiRefresh();
            return false;
        }

        _lastEndReason = VoiceProto.END_NONE;
        _lastEndEpoch = 0;
        persistSessionMeta();

        _sessionStartMs = System.getTimer();
        _sessionStartEpoch = Time.now().value();
        _stopping = false;
        _batStartPct = System.getSystemStats().battery.toNumber();
        _backArmMs = 0;

        // Monotonic segment id persisted across restarts/crashes (never reuse a crashed segId)
        var nextSeg = 1;
        var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
        if (fg != null && fg[4] >= 0) {
            nextSeg = fg[4] + 1;
        }

        configureForegroundBindings();
        setTouchEnabled(false);

        var started = _capture.startSession(nextSeg);
        if (started) {
            _ring.persistFgMeta(1, _capture.segId(), _capture.segEpoch());
        } else {
            _sessionStartEpoch = 0;
            setTouchEnabled(true);
            var reason = _capture.stopEndReason();
            recordEndReason((reason != VoiceProto.END_NONE) ? reason : VoiceProto.END_MIC_DENIED);
        }
        syncFaceState();
        requestUiRefresh();
        return started;
    }

    private function stopRecording(reason as Number) as Void {
        _stopping = true;
        syncFaceState();
        _capture.stopSession(reason);
        if (!_capture.isRecording()) {
            finalizeStoppedSession(reason);
        } else {
            requestUiRefresh();
        }
    }

    private function finalizeStoppedSession(reason as Number) as Void {
        _stopping = false;
        _sessionStartEpoch = 0;
        _backArmMs = 0;
        setTouchEnabled(true);
        recordEndReason(reason);
        _ring.persistFgMeta(0, _capture.segId(), _capture.segEpoch());
        syncFaceState();
        persistHealthAndQueueStatus();
        requestUiRefresh();
    }

    private function syncFaceState() as Void {
        var startEp = (_capture.isRecording() && _sessionStartEpoch > 0) ? _sessionStartEpoch : 0;
        _ring.writeFaceState(currentPhase(), currentReason(), _lastEndReason, startEp);
    }

    private function recordEndReason(reason as Number) as Void {
        _lastEndReason = reason;
        _lastEndEpoch = Time.now().value();
        persistSessionMeta();
    }

    private function restoreSessionMeta() as Void {
        var sm = VoiceProto.readIntArray(VoiceProto.K_SESSION_META, 7);
        if (sm != null) {
            _lastEndReason = sm[0];
            _lastEndEpoch = sm[1];
            _phoneProtoVer = sm[2];
            _phoneEverAcked = sm[3];
            _lastPhoneAckEpoch = sm[4];
            _tzLat100 = sm[5];
            _tzLon100 = sm[6];
        }
    }

    private function persistSessionMeta() as Void {
        var sm = [
            _lastEndReason,
            _lastEndEpoch,
            _phoneProtoVer,
            _phoneEverAcked,
            _lastPhoneAckEpoch,
            _tzLat100,
            _tzLon100
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_SESSION_META, sm);
    }

    private function configureForegroundBindings() as Void {
        disarmBackgroundTemporal();
        if (!_phoneRegistered) {
            try {
                Communications.registerForPhoneAppMessages(method(:onPhoneMessage));
                Communications.registerForPhoneAppMessageErrors(method(:onPhoneMessageError));
                _phoneRegistered = true;
            } catch (_) {}
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

    public function onPhoneMessage(msg as Communications.PhoneAppMessage) as Void {
        if (_tx.onPhoneMessage(msg, _ring)) {
            var ver = _tx.lastPhoneProtoVer();
            var ackEp = _tx.lastAckEpoch();
            var tzLat = _tx.lastTzLat100();
            var tzLon = _tx.lastTzLon100();
            var sessionDirty = false;
            if (ver >= 0 && ver != _phoneProtoVer) {
                _phoneProtoVer = ver;
                sessionDirty = true;
            }
            if (ackEp > _lastPhoneAckEpoch) {
                _lastPhoneAckEpoch = ackEp;
                sessionDirty = true;
            }
            if (tzLat != VoiceProto.TZ_UNSET && (tzLat != _tzLat100 || tzLon != _tzLon100)) {
                _tzLat100 = tzLat;
                _tzLon100 = tzLon;
                sessionDirty = true;
            }
            if (_phoneEverAcked == 0 && ackEp > 0) {
                _phoneEverAcked = 1;
                sessionDirty = true;
            }
            if (sessionDirty) {
                persistSessionMeta();
            }
            var fgActive = _capture.isRecording() ? 1 : 0;
            if (_ring.pendingCount() == 0 && _ring.needsCompaction()) {
                _ring.maybeCompactIfEmpty(fgActive, _capture.segId(), _capture.segEpoch());
            } else {
                _ring.persistFgMeta(fgActive, _capture.segId(), _capture.segEpoch());
            }
            syncFaceState();
            requestUiRefresh();
        }
    }

    public function onPhoneMessageError(err as Communications.PhoneAppMessageError) as Void {
        _tx.onPhoneMsgError();
        VoiceProto.vlog("SV phoneMsgErr");
    }

    public function onBackgroundData(data as Application.PersistableType) as Void {
        _ring.syncBgAck();
        var sessionDirty = false;
        if (data instanceof Dictionary) {
            var d = data as Dictionary;
            var rawA = d["a"];
            if (rawA instanceof Number && (rawA as Number) >= 0) {
                _ring.onAckConfirmed(rawA as Number);
                if (_phoneEverAcked == 0) {
                    _phoneEverAcked = 1;
                    sessionDirty = true;
                }
            }
            var rawT = d["t"];
            if (rawT instanceof Number) {
                var ackEp = rawT as Number;
                if (ackEp > _lastPhoneAckEpoch) {
                    _lastPhoneAckEpoch = ackEp;
                    sessionDirty = true;
                }
            }
            var tz = VoiceProto.parseAckTzPoint(d);
            if (tz != null && (tz[0] != _tzLat100 || tz[1] != _tzLon100)) {
                _tzLat100 = tz[0];
                _tzLon100 = tz[1];
                sessionDirty = true;
            }
        }
        if (sessionDirty) {
            persistSessionMeta();
        }
        _tx.resetCursor(_ring.ackedSeq());
        syncFaceState();
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
        return true;
    }

    public function onDisplayModeChanged() as Void {
        _highPower = isDisplayHighPower();
        if (_highPower) {
            WatchUi.requestUpdate();
        }
    }

    public function onMasterTick() as Void {
        var wasRecording = _capture.isRecording();
        var segSealed = _capture.tick(_ring);

        if (wasRecording && !_capture.isRecording()) {
            var endR = _capture.stopEndReason();
            if (endR == VoiceProto.END_NONE) {
                endR = _ring.isFull() ? VoiceProto.END_STORAGE_FULL : VoiceProto.END_USER_STOP;
            }
            finalizeStoppedSession(endR);
        }
        syncFaceState();

        // Batch into K=8 bursts while recording; flush down to 0 on segment seal, stop, or compaction
        var batchOnly = _capture.isRecording() && !segSealed && !_ring.needsCompaction();
        _tx.tick(_ring, batchOnly);

        _uiTick++;
        if (segSealed || (_uiTick % 40 == 0)) {
            _ring.maybeCompactIfEmpty(_capture.isRecording() ? 1 : 0, _capture.segId(), _capture.segEpoch());
            if (segSealed) {
                persistHealthAndQueueStatus();
            }
        }

        if (_highPower && (_uiTick % 4 == 0)) {
            WatchUi.requestUpdate();
        }
    }

    private function queueLocalStatusFrame() as Void {
        var st = System.getSystemStats();
        var batPct = st.battery.toNumber();
        var freeKb = st.freeMemory / 1024;
        var sFlags = (st.charging ? 1 : 0) |
                     (_capture.isStalled() ? 2 : 0) |
                     (_ring.isFull() ? 4 : 0) |
                     (_capture.hasLiveAudio() ? 8 : 0) |
                     (_capture.isInterrupted() ? 16 : 0);
        var frame = VoiceProto.buildStatusFrame(
            batPct, _capture.segId(), freeKb,
            _ring.writeMaxMs(), _capture.droppedChunks(),
            _ring.bgWakeCount(), _ring.resetCount(),
            _tx.totalTxErr(), _ring.pendingCount(),
            sFlags, _lastEndReason, _statusEncOpts
        );
        _tx.queueStatus(frame);
    }

    private function persistHealthAndQueueStatus() as Void {
        var health = [
            _batStartPct,
            _capture.segsCompleted(),
            _ring.writeMaxMs(),
            _ring.writeCount(),
            _capture.isStalled() ? 1 : 0,
            VoiceProto.MODE_FG_BURST
        ] as Array<Number>;
        VoiceProto.writeIntArray(VoiceProto.K_HEALTH, health);
        queueLocalStatusFrame();
    }

    private function requestUiRefresh() as Void {
        if (_highPower) {
            WatchUi.requestUpdate();
        }
    }

    public function shutdown() as Void {
        _timer.stop();
        var wasRec = _capture.isRecording();
        var relMs = _capture.segElapsedMs();
        _capture.forceStopImmediate();
        _capture.tick(_ring);
        if (wasRec) {
            _ring.flushSegmentTail(_capture.rateKhz(), _capture.segId(), _capture.segEpoch(), _capture.tzOffsetMin(), relMs, true);
            if (_lastEndReason == VoiceProto.END_NONE) {
                recordEndReason(VoiceProto.END_USER_STOP);
            }
        }
        _sessionStartEpoch = 0;
        _stopping = false;
        setTouchEnabled(true);
        _ring.persistFgMeta(0, _capture.segId(), _capture.segEpoch());
        syncFaceState();
        persistHealthAndQueueStatus();

        if (_ring.pendingCount() > 0) {
            armBackgroundDrain();
        } else {
            disarmBackgroundTemporal();
        }
        VoiceProto.vlog("SV FG stop pending=" + _ring.pendingCount() + " maxW=" + _ring.writeMaxMs() + "ms");
    }

    (:debug)
    public function testStopTimer() as Void {
        _timer.stop();
    }
}
