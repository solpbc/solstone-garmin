// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// Reads the controller's snapshot into FaceFacts. The only place the face touches session state.
module FaceSource {
    function facts(snap as VoiceSnapshot, confirmStop as Boolean) as FaceFacts {
        var f = new FaceFacts();
        f.phase = snap.phase;
        var engaged = snap.phase != VoiceProto.PHASE_READY;
        var now = Time.now().value();
        var start = snap.startEpoch;
        f.elapsedSec = start != null && now >= start ? now - start : 0;
        f.heldSec = snap.heldSec;
        f.capSec = snap.capSec;
        f.confirmStop = confirmStop && engaged;
        f.phoneAgoSec = -1;
        if (snap.phoneLinked) {
            var at = snap.lastPhoneEpoch;
            f.phoneAgoSec = at != null && now >= at ? now - at : -2;
        }

        // Worst first: the launch, then live audio, then storage and the microphone, then what
        // ended the last session, then versions, then a phone that has never answered.
        var r = snap.reason;
        var end = snap.lastEnd;
        if (r == VoiceProto.REASON_TIMEOUT_LAUNCH && !engaged) {
            f.reason = Face.REASON_TIMEOUT_LAUNCH;
        } else if (engaged && (r == VoiceProto.REASON_MIC_STALLED || snap.interrupted)) {
            f.reason = Face.REASON_MIC_STALLED;
        } else if (r == VoiceProto.REASON_STORAGE_FULL || (!engaged && end == VoiceProto.END_STORAGE_FULL)) {
            f.reason = Face.REASON_STORAGE_FULL;
        } else if (r == VoiceProto.REASON_MIC_PERMISSION || (!engaged && end == VoiceProto.END_MIC_DENIED)) {
            f.reason = Face.REASON_MIC_PERMISSION;
        } else if (!engaged && end == VoiceProto.END_MIC_ERROR) {
            f.reason = Face.REASON_MIC_STOPPED;
        } else if (!engaged && end == VoiceProto.END_UNEXPECTED) {
            f.reason = Face.REASON_ENDED;
        } else if (r == VoiceProto.REASON_PHONE_TOO_OLD) {
            f.reason = Face.REASON_PHONE_TOO_OLD;
        } else if (r == VoiceProto.REASON_WATCH_TOO_OLD) {
            f.reason = Face.REASON_WATCH_TOO_OLD;
        } else if (!engaged && !snap.phoneLinked) {
            f.reason = Face.REASON_NO_PHONE;
        }
        return f;
    }

    // The paired phone's time-zone reference point, in hundredths of a degree, once it has sent one.
    function sunPoint(snap as VoiceSnapshot) as Array<Number>? {
        var lat = snap.tzLat100;
        var lon = snap.tzLon100;
        return lat != null && lon != null ? [lat, lon] : null;
    }
}

// The first screen and, one press down, the details. Touch is off for a session's length,
// so every action also works on the enter and back keys alone.
class VoiceView extends WatchUi.View {
    private var _ctrl as VoiceController;
    private var _details as Boolean = false;
    private var _confirmAtMs as Number = 0;
    private var _pairDay as Number = -1;
    private var _pair as Array<Float> = [390.0f, 1170.0f];

    const CONFIRM_MS = 3000;

    public function initialize(ctrl as VoiceController) {
        View.initialize();
        _ctrl = ctrl;
    }

    public function showDetails(on as Boolean) as Void {
        _details = on;
        WatchUi.requestUpdate();
    }

    public function isDetails() as Boolean {
        return _details;
    }

    public function confirmArmed() as Boolean {
        return _confirmAtMs != 0 && (System.getTimer() - _confirmAtMs) < CONFIRM_MS;
    }

    public function armConfirm() as Void {
        _confirmAtMs = System.getTimer();
        WatchUi.requestUpdate();
    }

    public function clearConfirm() as Void {
        _confirmAtMs = 0;
    }

    private function style() as SunArc.Style {
        if (!(System has :getDisplayMode)) {
            return SunArc.STYLE_OUTLINE;
        }
        return System.getDisplayMode() == System.DISPLAY_MODE_HIGH_POWER ? SunArc.STYLE_FULL : SunArc.STYLE_DIM;
    }

    // Sunrise and sunset, recomputed once a day and whenever the point changes.
    private function pair(snap as VoiceSnapshot) as Array<Float> {
        var day = Time.today().value() / 86400;
        var point = FaceSource.sunPoint(snap);
        var key = day + (point != null ? point[0] * 7 + point[1] : 0);
        if (key != _pairDay) {
            _pair = SunArc.solarPair(point, null);
            _pairDay = key;
        }
        return _pair;
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        if (System has :getDisplayMode && System.getDisplayMode() == System.DISPLAY_MODE_OFF) {
            return;
        }
        var st = style();
        var snap = _ctrl.getSnapshot();
        SunArc.draw(dc, st, SunArc.nowMinute(), pair(snap));
        if (st == SunArc.STYLE_DIM) {
            return;
        }
        var armed = confirmArmed();
        if (!armed) {
            _confirmAtMs = 0;
        }
        var f = FaceSource.facts(snap, armed);
        // The complication follows what the face shows.
        var attention = f.reason == Face.REASON_MIC_STALLED || f.control() == Face.CONTROL_DETAILS;
        ComplicationState.publish(f.engaged()
            ? (attention ? ComplicationState.VALUE_ATTENTION : ComplicationState.VALUE_ON)
            : (attention ? ComplicationState.VALUE_ATTENTION : ComplicationState.VALUE_OFF));
        if (_details) {
            FaceDraw.details(dc, f);
        } else {
            FaceDraw.first(dc, f);
        }
    }
}

class VoiceInputDelegate extends WatchUi.BehaviorDelegate {
    private var _ctrl as VoiceController;
    private var _view as VoiceView;

    public function initialize(ctrl as VoiceController, view as VoiceView) {
        BehaviorDelegate.initialize();
        _ctrl = ctrl;
        _view = view;
    }

    // Start at once; stop only on a second press within three seconds.
    public function onSelect() as Boolean {
        if (_ctrl.isTimeoutLaunch() && !_ctrl.isRecording()) {
            return true;
        }
        // On the details page of a watch that has never reached the phone, enter sends the setup link there.
        if (_view.isDetails() && !_ctrl.isRecording() && !_ctrl.isStarting() && !_ctrl.isPhoneLinked()) {
            _ctrl.requestLinkPhone();
            return true;
        }
        if (_ctrl.isRecording() || _ctrl.isStarting()) {
            if (_view.confirmArmed()) {
                _view.clearConfirm();
                _ctrl.toggleRecording();
                WatchUi.requestUpdate();
            } else {
                _view.armConfirm();
            }
            return true;
        }
        var end = _ctrl.lastEndReason();
        if (!_view.isDetails() && (end == VoiceProto.END_UNEXPECTED || end == VoiceProto.END_MIC_DENIED
                || end == VoiceProto.END_STORAGE_FULL || end == VoiceProto.END_MIC_ERROR)) {
            // The control reads "details" after a failure: show what happened first.
            _view.showDetails(true);
            return true;
        }
        _view.showDetails(false);
        _ctrl.toggleRecording();
        WatchUi.requestUpdate();
        return true;
    }

    public function onNextPage() as Boolean {
        _view.showDetails(true);
        return true;
    }

    public function onPreviousPage() as Boolean {
        leaveDetails();
        return true;
    }

    // Once the owner has read why the last session ended, the face goes back to start.
    private function leaveDetails() as Void {
        if (_view.isDetails() && !_ctrl.isRecording()) {
            _ctrl.dismissLastEndReason();
        }
        _view.showDetails(false);
    }

    // During a session back shows the details and never leaves: on some watches leaving ends the session.
    public function onBack() as Boolean {
        if (_view.isDetails()) {
            leaveDetails();
            return true;
        }
        if (_ctrl.isRecording() || _ctrl.isStarting()) {
            _view.showDetails(true);
            return true;
        }
        return false;
    }

    public function onMenu() as Boolean {
        if (!_ctrl.isPhoneLinked()) {
            _ctrl.requestLinkPhone();
        }
        return true;
    }
}
