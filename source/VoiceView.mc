// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Battery-stingy AMOLED-friendly status view (pure black background, minimal primitives, <=1 Hz in high power only)
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

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (_ctrl.isTimeoutLaunch()) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 38) / 100, Graphics.FONT_MEDIUM, "OPEN FROM", Graphics.TEXT_JUSTIFY_CENTER);
            dc.drawText(cx, (h * 50) / 100, Graphics.FONT_MEDIUM, "APPS MENU", Graphics.TEXT_JUSTIFY_CENTER);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 66) / 100, Graphics.FONT_XTINY, "Glance launches time out", Graphics.TEXT_JUSTIFY_CENTER);
            return;
        }

        var connected = System.getDeviceSettings().phoneConnected;
        var stats = System.getSystemStats();
        var batPct = stats.battery.toNumber();
        var freeKb = stats.freeMemory / 1024;

        // Top: Mode + phone link indicator dot
        dc.setColor(connected ? Graphics.COLOR_GREEN : Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, (h * 12) / 100, 6);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 17) / 100, Graphics.FONT_XTINY, VoiceProto.modeName(_ctrl.mode()), Graphics.TEXT_JUSTIFY_CENTER);

        // Hero state & elapsed clock
        var statusTxt = "READY";
        var statusClr = Graphics.COLOR_WHITE;
        var capState = _ctrl.captureState();
        if (_ctrl.isStorageFull()) {
            statusTxt = "STORAGE FULL";
            statusClr = Graphics.COLOR_ORANGE;
        } else if (_ctrl.isStalled()) {
            statusTxt = "MIC STALLED";
            statusClr = Graphics.COLOR_RED;
        } else if (capState == VoiceCaptureEngine.CAP_QUIET_WAIT) {
            statusTxt = "SYNC BURST";
            statusClr = Graphics.COLOR_BLUE;
        } else if (_ctrl.isRecording()) {
            statusTxt = "REC";
            statusClr = Graphics.COLOR_RED;
        }

        dc.setColor(statusClr, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 28) / 100, Graphics.FONT_MEDIUM, statusTxt, Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 41) / 100, Graphics.FONT_NUMBER_MILD, formatElapsed(_ctrl.elapsedSec()), Graphics.TEXT_JUSTIFY_CENTER);

        // Mid metrics: Segments, Queue pending, Acked
        var ackDisplay = (_ctrl.ackedSeq() >= 0) ? _ctrl.ackedSeq() : 0;
        var line1 = "S" + _ctrl.segId() + "  Q:" + _ctrl.pendingCount() + "  A:" + ackDisplay;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, (h * 60) / 100, Graphics.FONT_XTINY, line1, Graphics.TEXT_JUSTIFY_CENTER);

        var line2 = "Bat:" + batPct + "%  Mem:" + freeKb + "K";
        if (_ctrl.mode() == VoiceProto.MODE_BG_DRAIN) {
            line2 = line2 + "  BG:" + _ctrl.bgWakeCount();
        }
        dc.drawText(cx, (h * 69) / 100, Graphics.FONT_XTINY, line2, Graphics.TEXT_JUSTIFY_CENTER);

        // Bottom control hint / double-BACK confirmation guard
        var hint = "UP/DN Mode | START";
        var hintClr = Graphics.COLOR_DK_GRAY;
        if (_ctrl.isBackConfirmArmed()) {
            hint = "PRESS BACK TO EXIT";
            hintClr = Graphics.COLOR_ORANGE;
        } else if (_ctrl.isRecording()) {
            hint = "START Stop | 2xBACK";
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

    public function initialize(ctrl as VoiceController) {
        BehaviorDelegate.initialize();
        _ctrl = ctrl;
    }

    public function onSelect() as Boolean {
        _ctrl.toggleRecording();
        return true;
    }

    public function onPreviousPage() as Boolean {
        _ctrl.cycleMode(-1);
        return true;
    }

    public function onNextPage() as Boolean {
        _ctrl.cycleMode(1);
        return true;
    }

    public function onMenu() as Boolean {
        _ctrl.cycleMode(1);
        return true;
    }

    public function onBack() as Boolean {
        return _ctrl.handleBackPress();
    }
}
