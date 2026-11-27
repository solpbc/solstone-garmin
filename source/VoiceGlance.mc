// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Time;
import Toybox.WatchUi;

// The glance shows state by shape and a few words, and only opens the app.
// The full sun: audio is going in. The bare ring: not running. A ring with "!":
// something needs the owner. A ring with "?": the glance can't tell.
(:glance)
module GlanceMark {
    enum State {
        STATE_UNKNOWN = 0,
        STATE_READY = 1,
        STATE_ACTIVE = 2,
        STATE_ATTENTION = 3
    }

    const GOLD = 0xFFCC33;
    const ORANGE = 0xE8913A;
    const CREAM = 0xF4EEE4;
    const CALM = 0xD9D9E1;

    function draw(dc as Graphics.Dc, cx as Number, cy as Number, r as Number, state as Number) as Void {
        var s = r / 13.5f;
        var ringR = (6.5f * s).toNumber();
        var pen = ((2 / 1.618f + 0.5f) * s).toNumber();
        if (pen < 2) {
            pen = 2;
        }
        if (state == STATE_ACTIVE) {
            dc.setColor(GOLD, Graphics.COLOR_TRANSPARENT);
            var base = 8.5f + 1 / 1.618f;
            var half = Math.toRadians(16.5f);
            for (var k = 0; k < 10; k++) {
                var rot = Math.toRadians(36.0f * k);
                var tipA = rot - Math.PI / 2;
                var la = tipA - half;
                var ra = tipA + half;
                dc.fillPolygon([
                    [cx + (13.5f * s * Math.cos(tipA)).toNumber(), cy + (13.5f * s * Math.sin(tipA)).toNumber()],
                    [cx + (base * s * Math.cos(ra)).toNumber(), cy + (base * s * Math.sin(ra)).toNumber()],
                    [cx + (base * s * Math.cos(tipA)).toNumber(), cy + (base * s * Math.sin(tipA)).toNumber()],
                    [cx + (base * s * Math.cos(la)).toNumber(), cy + (base * s * Math.sin(la)).toNumber()]
                ]);
            }
            dc.setColor(ORANGE, Graphics.COLOR_TRANSPARENT);
        } else {
            dc.setColor(state == STATE_READY ? CALM : CREAM, Graphics.COLOR_TRANSPARENT);
        }
        dc.setPenWidth(pen);
        dc.drawCircle(cx, cy, state == STATE_ACTIVE ? ringR : (r * 7) / 10);
        dc.setPenWidth(1);
        if (state == STATE_ATTENTION || state == STATE_UNKNOWN) {
            dc.drawText(cx, cy, Graphics.FONT_XTINY, state == STATE_ATTENTION ? "!" : "?",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // The glance row: the mark, the name, and one line.
    function row(dc as Graphics.Dc, state as Number, line as String) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var r = h * 32 / 100;
        if (r > w / 8) {
            r = w / 8;
        }
        draw(dc, r + 2, h / 2, r, state);
        var x = r * 2 + r / 2 + 4;
        dc.setColor(CREAM, Graphics.COLOR_TRANSPARENT);
        var th = dc.getFontHeight(Graphics.FONT_GLANCE);
        dc.drawText(x, h / 2 - th / 2, Graphics.FONT_GLANCE, WatchUi.loadResource(Rez.Strings.AppName) as String,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(CALM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h / 2 + th / 2, Graphics.FONT_GLANCE, line, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}

// The glance reads what the app last stored and never touches the microphone or the phone.
(:glance)
class VoiceGlanceView extends WatchUi.GlanceView {
    // A foreground heartbeat older than this means the app is no longer running.
    const STALE_SEC = 120;
    const SEC_PER_SLAB = 2;

    public function initialize() {
        GlanceView.initialize();
    }

    private function read(key as Number) as Array<Number>? {
        var v = Application.Storage.getValue(key);
        return v instanceof Array ? v as Array<Number> : null;
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        var state = GlanceMark.STATE_UNKNOWN;
        var line = WatchUi.loadResource(Rez.Strings.GlanceUnknown) as String;
        try {
            var fg = read(VoiceProto.K_FG_META);
            var bg = read(VoiceProto.K_BG_META);
            var sm = read(VoiceProto.K_SESSION_META);
            if (fg != null && fg.size() >= 7) {
                var end = (sm != null && sm.size() > 0) ? sm[0] : VoiceProto.END_NONE;
                var acked = fg[1];
                if (bg != null && bg.size() > 0 && bg[0] > acked) {
                    acked = bg[0];
                }
                var held = (fg[0] - 1 - acked) * SEC_PER_SLAB;
                var fresh = (Time.now().value() - fg[6]) < STALE_SEC;
                if (fg[2] == 1 && fresh) {
                    state = GlanceMark.STATE_ACTIVE;
                    line = WatchUi.loadResource(Rez.Strings.GlanceRunning) as String;
                } else if (fg[2] == 1 || end == VoiceProto.END_UNEXPECTED) {
                    state = GlanceMark.STATE_ATTENTION;
                    line = WatchUi.loadResource(Rez.Strings.PillEnded) as String;
                } else if (end == VoiceProto.END_STORAGE_FULL) {
                    state = GlanceMark.STATE_ATTENTION;
                    line = WatchUi.loadResource(Rez.Strings.PillStorageFull) as String;
                } else if (end == VoiceProto.END_MIC_DENIED || end == VoiceProto.END_MIC_ERROR) {
                    state = GlanceMark.STATE_ATTENTION;
                    line = WatchUi.loadResource(end == VoiceProto.END_MIC_DENIED ? Rez.Strings.PillMicPermission : Rez.Strings.PillMicStopped) as String;
                } else if (held > 0) {
                    state = GlanceMark.STATE_READY;
                    line = Lang.format(WatchUi.loadResource(Rez.Strings.GlanceHeld) as String, [((held + 59) / 60).toString()]);
                } else {
                    state = GlanceMark.STATE_READY;
                    line = WatchUi.loadResource(Rez.Strings.GlanceReady) as String;
                }
            }
        } catch (e) {
            state = GlanceMark.STATE_UNKNOWN;
        }
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        GlanceMark.row(dc, state, line);
    }
}
