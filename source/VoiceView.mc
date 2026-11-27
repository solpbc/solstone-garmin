// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Minimal status view (replaced by the final watch face pass).
// Renders every VoiceController state honestly with zero color-only meaning.
class VoiceView extends WatchUi.View {
    private var _ctrl as VoiceController;

    public function initialize(ctrl as VoiceController) {
        View.initialize();
        _ctrl = ctrl;
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var snap = _ctrl.getSnapshot();

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (snap.reason == VoiceProto.REASON_TIMEOUT_LAUNCH) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 34) / 100, Graphics.FONT_MEDIUM, "OPEN FROM", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, (h * 46) / 100, Graphics.FONT_MEDIUM, "APPS MENU", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 64) / 100, Graphics.FONT_XTINY, "Shortcuts stay active", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var connected = snap.phoneLink;
        var stats = System.getSystemStats();
        var batPct = stats.battery.toNumber();

        // Top: phone link status text (not color-only)
        dc.setColor(connected ? Graphics.COLOR_GREEN : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var linkLabel = connected ? (snap.phoneLinked ? "PHONE READY" : "LINK PHONE") : "PHONE AWAY";
        dc.drawText(cx, (h * 14) / 100, Graphics.FONT_XTINY, linkLabel, Graphics.TEXT_JUSTIFY_CENTER);

        // Hero state (active only when live audio is actually arriving)
        var statusTxt = "READY";
        var statusClr = Graphics.COLOR_WHITE;
        if (snap.reason == VoiceProto.REASON_STORAGE_FULL) {
            statusTxt = "WATCH FULL";
            statusClr = Graphics.COLOR_ORANGE;
        } else if (snap.reason == VoiceProto.REASON_MIC_STALLED) {
            statusTxt = "NEEDS ATTENTION";
            statusClr = Graphics.COLOR_RED;
        } else if (snap.reason == VoiceProto.REASON_MIC_PERMISSION) {
            statusTxt = "MIC NEEDED";
            statusClr = Graphics.COLOR_ORANGE;
        } else if (snap.interrupted) {
            statusTxt = "INTERRUPTED";
            statusClr = Graphics.COLOR_ORANGE;
        } else if (snap.phase == VoiceProto.PHASE_ACTIVE) {
            statusTxt = "ACTIVE";
            statusClr = Graphics.COLOR_RED;
        } else if (snap.phase == VoiceProto.PHASE_STARTING) {
            statusTxt = "STARTING...";
            statusClr = Graphics.COLOR_YELLOW;
        } else if (snap.phase == VoiceProto.PHASE_STOPPING) {
            statusTxt = "STOPPING...";
            statusClr = Graphics.COLOR_YELLOW;
        } else {
            if (snap.lastEnd == VoiceProto.END_MIC_ERROR) {
                statusTxt = "MIC ERROR";
                statusClr = Graphics.COLOR_RED;
            } else if (snap.lastEnd == VoiceProto.END_UNEXPECTED) {
                statusTxt = "ENDED EARLY";
                statusClr = Graphics.COLOR_ORANGE;
            } else if (snap.lastEnd == VoiceProto.END_STORAGE_FULL) {
                statusTxt = "WATCH FULL";
                statusClr = Graphics.COLOR_ORANGE;
            }
        }

        dc.setColor(statusClr, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 27) / 100, Graphics.FONT_MEDIUM, statusTxt, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 41) / 100, Graphics.FONT_NUMBER_MILD, formatElapsed(_ctrl.elapsedSec()), Graphics.TEXT_JUSTIFY_CENTER);

        // Mid status: waiting queue + battery
        var line1 = (snap.pendingSlabs > 0) ? ("WAITING: " + snap.heldSec + "s") : "ALL SENT";
        if (snap.reason == VoiceProto.REASON_PHONE_TOO_OLD) {
            line1 = "UPDATE PHONE APP";
        } else if (snap.reason == VoiceProto.REASON_WATCH_TOO_OLD) {
            line1 = "UPDATE WATCH APP";
        }
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 60) / 100, Graphics.FONT_XTINY, line1, Graphics.TEXT_JUSTIFY_CENTER);
        dc.drawText(cx, (h * 69) / 100, Graphics.FONT_XTINY, "BAT " + batPct + "%", Graphics.TEXT_JUSTIFY_CENTER);

        // Bottom control hint
        var hint = "START TO BEGIN";
        var hintClr = Graphics.COLOR_DK_GRAY;
        if (_ctrl.isBackConfirmArmed()) {
            hint = "PRESS BACK TO EXIT";
            hintClr = Graphics.COLOR_ORANGE;
        } else if (snap.phase == VoiceProto.PHASE_ACTIVE || snap.phase == VoiceProto.PHASE_STARTING) {
            hint = "START STOP | 2xBACK";
        } else if (connected && !snap.phoneLinked) {
            hint = "MENU LINK | START";
        }
        dc.setColor(hintClr, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 81) / 100, Graphics.FONT_XTINY, hint, Graphics.TEXT_JUSTIFY_CENTER);
    }

    private function formatElapsed(sec as Number) as String {
        var h = sec / 3600;
        var m = (sec % 3600) / 60;
        var s = sec % 60;
        if (h > 0) {
            return h.format("%d") + ":" + m.format("%02d") + ":" + s.format("%02d");
        }
        return m.format("%02d") + ":" + s.format("%02d");
    }
}

// Button-first delegate (5-button and 2-button watches; touch disabled while recording)
class VoiceInputDelegate extends WatchUi.BehaviorDelegate {
    private var _ctrl as VoiceController;

    public function initialize(ctrl as VoiceController, view as VoiceView) {
        BehaviorDelegate.initialize();
        _ctrl = ctrl;
    }

    public function onSelect() as Boolean {
        _ctrl.toggleRecording();
        return true;
    }

    public function onMenu() as Boolean {
        if (!_ctrl.isRecording()) {
            _ctrl.requestLinkPhone();
        }
        return true;
    }

    public function onBack() as Boolean {
        return _ctrl.handleBackPress();
    }
}
