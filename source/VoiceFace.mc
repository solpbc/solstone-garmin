// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.WatchUi;

// What the face shows, from facts alone. Nothing here touches the microphone,
// storage or the phone link; VoiceView fills FaceFacts from the controller.
module Face {
    enum Phase {
        PHASE_READY = 0,
        PHASE_STARTING = 1,
        PHASE_ACTIVE = 2,
        PHASE_STOPPING = 3
    }

    // The one reason the owner is asked to look, worst first.
    enum Reason {
        REASON_NONE = 0,
        REASON_TIMEOUT_LAUNCH = 1,
        REASON_MIC_PERMISSION = 2,
        REASON_MIC_STALLED = 3,
        REASON_STORAGE_FULL = 4,
        REASON_ENDED = 5,
        REASON_PHONE_TOO_OLD = 6,
        REASON_WATCH_TOO_OLD = 7,
        REASON_MIC_STOPPED = 8,
        REASON_NO_PHONE = 9
    }

    enum Control {
        CONTROL_NONE = 0,
        CONTROL_START = 1,
        CONTROL_STOP = 2,
        CONTROL_CONFIRM = 3,
        CONTROL_DETAILS = 4,
        CONTROL_LINK = 5
    }

    // Usage tokens for the watch face (dark watch roles over the sun).
    const CREAM = 0xF4EEE4;
    const CALM = 0xD9D9E1;
    const LIVE = 0xFED0A7;
    const ALERT = 0xFECEC7;
    const ALERT_DOT = 0xFF6B5E;
    const UNDERLAY = 0x2E241C;
    const ORANGE = 0xE8913A;
    const INK = 0x1A1A1A;

    // Two-button watches have only enter and back; their enter key sits on the right edge.
    function isRect(dc as Graphics.Dc) as Boolean {
        return System.getDeviceSettings().screenShape == System.SCREEN_SHAPE_RECTANGLE;
    }

    // A MIP screen has 64 colours, where the warm underlay lands on dark red: panels go black with a grey edge.
    function isMip() as Boolean {
        return !(System has :getDisplayMode);
    }

    function underlay() as Number {
        return isMip() ? 0x000000 : UNDERLAY;
    }

    function str(id as ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }

    function fmt(id as ResourceId, value as String) as String {
        return Lang.format(str(id), [value]);
    }

    function elapsedText(sec as Number) as String {
        var s = sec < 0 ? 0 : sec;
        if (s < 60) {
            return fmt(Rez.Strings.SecondsShort, s.toString());
        }
        var m = s / 60;
        if (m < 60) {
            return fmt(Rez.Strings.MinutesShort, m.toString());
        }
        return Lang.format(str(Rez.Strings.HoursMinutesShort), [(m / 60).toString(), (m % 60).toString()]);
    }

    function minutesText(sec as Number) as String {
        var m = (sec + 30) / 60;
        if (sec > 0 && m < 1) {
            return str(Rez.Strings.UnderAMinute);
        }
        return fmt(Rez.Strings.MinutesHeld, m.toString());
    }
}

class FaceFacts {
    public var phase as Number = Face.PHASE_READY;
    public var reason as Number = Face.REASON_NONE;
    public var elapsedSec as Number = 0;
    // About how much audio waits on the watch, in seconds; -1 when it couldn't be read.
    public var heldSec as Number = -1;
    // About how much the watch can hold away from the phone, in seconds.
    public var capSec as Number = 2160;
    // Seconds since the phone last confirmed something; -1 when it never has, -2 when it has but the time is unknown.
    public var phoneAgoSec as Number = -1;
    public var confirmStop as Boolean = false;

    public function initialize() {
    }

    public function engaged() as Boolean {
        return phase == Face.PHASE_STARTING || phase == Face.PHASE_ACTIVE || phase == Face.PHASE_STOPPING;
    }

    public function control() as Number {
        if (reason == Face.REASON_TIMEOUT_LAUNCH && !engaged()) {
            return Face.CONTROL_NONE;
        }
        if (engaged()) {
            return confirmStop ? Face.CONTROL_CONFIRM : Face.CONTROL_STOP;
        }
        if (reason == Face.REASON_ENDED || reason == Face.REASON_STORAGE_FULL || reason == Face.REASON_MIC_PERMISSION
                || reason == Face.REASON_MIC_STOPPED) {
            return Face.CONTROL_DETAILS;
        }
        return Face.CONTROL_START;
    }

    // The first screen's attention pill, or null when nothing needs the owner.
    public function pill() as String? {
        switch (reason) {
            case Face.REASON_TIMEOUT_LAUNCH: return Face.str(Rez.Strings.PillTimeout);
            case Face.REASON_MIC_PERMISSION: return Face.str(Rez.Strings.PillMicPermission);
            case Face.REASON_MIC_STALLED: return Face.str(Rez.Strings.PillMicStalled);
            case Face.REASON_STORAGE_FULL: return Face.str(Rez.Strings.PillStorageFull);
            case Face.REASON_ENDED: return Face.str(Rez.Strings.PillEnded);
            case Face.REASON_PHONE_TOO_OLD: return Face.str(Rez.Strings.PillPhoneTooOld);
            case Face.REASON_WATCH_TOO_OLD: return Face.str(Rez.Strings.PillWatchTooOld);
            case Face.REASON_MIC_STOPPED: return Face.str(Rez.Strings.PillMicStopped);
            case Face.REASON_NO_PHONE: return Face.str(Rez.Strings.PillNoPhone);
        }
        return null;
    }

    // The details page's next step, or null.
    public function nextStep() as String? {
        switch (reason) {
            case Face.REASON_TIMEOUT_LAUNCH: return Face.str(Rez.Strings.StepTimeout);
            case Face.REASON_MIC_PERMISSION: return Face.str(Rez.Strings.StepMicPermission);
            case Face.REASON_MIC_STALLED: return Face.str(Rez.Strings.StepMicStalled);
            case Face.REASON_STORAGE_FULL: return Face.str(Rez.Strings.StepStorageFull);
            case Face.REASON_ENDED: return Face.str(Rez.Strings.StepEnded);
            case Face.REASON_PHONE_TOO_OLD: return Face.str(Rez.Strings.StepPhoneTooOld);
            case Face.REASON_WATCH_TOO_OLD: return Face.str(Rez.Strings.StepWatchTooOld);
            case Face.REASON_MIC_STOPPED: return Face.str(Rez.Strings.StepMicStopped);
        }
        if (phoneAgoSec == -1) {
            return Face.str(Rez.Strings.StepNoPhone);
        }
        if (heldSec > 0 && phoneAgoSec > 1800) {
            return Face.str(Rez.Strings.StepQuietPhone);
        }
        return null;
    }

    public function heldText() as String {
        return heldSec < 0 ? Face.str(Rez.Strings.CouldntCheck) : Face.minutesText(heldSec);
    }

    public function phoneText() as String {
        if (phoneAgoSec == -1) {
            return Face.str(Rez.Strings.NotYet);
        }
        if (phoneAgoSec < 0) {
            return Face.str(Rez.Strings.CouldntCheck);
        }
        if (phoneAgoSec < 120) {
            return Face.str(Rez.Strings.JustNow);
        }
        if (phoneAgoSec < 3600) {
            return Face.fmt(Rez.Strings.MinutesAgo, (phoneAgoSec / 60).toString());
        }
        return Face.fmt(Rez.Strings.HoursAgo, (phoneAgoSec / 3600).toString());
    }
}

// Draws the first screen and the details page over the sun.
module FaceDraw {
    function textWidth(dc as Graphics.Dc, text as String, font as Graphics.FontType) as Number {
        return dc.getTextWidthInPixels(text, font);
    }

    function roundRect(dc as Graphics.Dc, x as Number, y as Number, w as Number, h as Number, fill as Number) as Void {
        panel(dc, x, y, w, h, h / 2, fill);
    }

    // An opaque panel; on MIP, a black one with a grey edge.
    function panel(dc as Graphics.Dc, x as Number, y as Number, w as Number, h as Number, r as Number, fill as Number) as Void {
        var mip = Face.isMip();
        dc.setColor(mip && fill == Face.UNDERLAY ? 0x000000 : fill, Graphics.COLOR_TRANSPARENT);
        dc.fillRoundedRectangle(x, y, w, h, r);
        if (mip && fill == Face.UNDERLAY) {
            dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawRoundedRectangle(x, y, w, h, r);
            dc.setPenWidth(1);
        }
    }

    // How wide a line may be at height y: the chord of a round screen, less a margin.
    function widthAt(dc as Graphics.Dc, y as Number, lineH as Number, margin as Number) as Number {
        var w = dc.getWidth();
        if (Face.isRect(dc)) {
            return w - margin * 2;
        }
        var r = w / 2;
        var cy = dc.getHeight() / 2;
        var dyTop = (y - cy).abs();
        var dyBot = (y + lineH - cy).abs();
        var dy = dyTop > dyBot ? dyTop : dyBot;
        if (dy >= r) {
            return 0;
        }
        return (2 * Math.sqrt(r * r - dy * dy)).toNumber() - margin * 2;
    }

    // Draws text centred, wrapped word by word to the screen's shape, from y down to at most maxY.
    // Returns the y below the last line drawn.
    function block(dc as Graphics.Dc, text as String, font as Graphics.FontType, color as Number, y as Number, maxY as Number, margin as Number) as Number {
        var lh = dc.getFontHeight(font);
        var words = [] as Array<String>;
        var chars = text.toCharArray();
        var cur = "";
        for (var i = 0; i < chars.size(); i++) {
            var c = chars[i];
            if (c == ' ' || c == '\n') {
                if (cur.length() > 0) {
                    words.add(cur);
                }
                if (c == '\n') {
                    words.add("\n");
                }
                cur = "";
            } else {
                cur += c.toString();
            }
        }
        if (cur.length() > 0) {
            words.add(cur);
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        var line = "";
        var k = 0;
        while (k <= words.size()) {
            var word = k < words.size() ? words[k] : null;
            var maxW = widthAt(dc, y, lh, margin);
            var newline = word != null && word.equals("\n");
            var trial = (word == null || newline) ? line : (line.length() == 0 ? word : line + " " + word);
            if (word != null && !newline && (line.length() == 0 || textWidth(dc, trial, font) <= maxW)) {
                line = trial;
                k++;
                continue;
            }
            if (y + lh > maxY) {
                return y;
            }
            if (line.length() > 0) {
                dc.drawText(dc.getWidth() / 2, y, font, line, Graphics.TEXT_JUSTIFY_CENTER);
                y += lh;
            }
            line = "";
            if (word == null) {
                break;
            }
            if (newline) {
                k++;
            }
        }
        return y;
    }

    // Splits a line at the space nearest its middle.
    function split(text as String) as Array<String> {
        var chars = text.toCharArray();
        var mid = chars.size() / 2;
        var best = -1;
        for (var i = 0; i < chars.size(); i++) {
            if (chars[i] == ' ' && (best < 0 || (i - mid).abs() < (best - mid).abs())) {
                best = i;
            }
        }
        if (best < 0) {
            return [text];
        }
        return [text.substring(0, best) as String, text.substring(best + 1, chars.size()) as String];
    }

    // The attention pill: a dot and a few words on an opaque underlay, on two lines if it must.
    function pill(dc as Graphics.Dc, text as String, cy as Number) as Void {
        var w = dc.getWidth();
        var font = Graphics.FONT_XTINY;
        var th = dc.getFontHeight(font);
        var dot = th / 4;
        var lines = [text];
        var maxText = (w * 80) / 100 - th - dot * 2;
        if (textWidth(dc, text, font) > maxText) {
            lines = split(text);
        }
        var tw = 0;
        for (var i = 0; i < lines.size(); i++) {
            var lw = textWidth(dc, lines[i], font);
            tw = lw > tw ? lw : tw;
        }
        var ph = (th * 14) / 10 + (lines.size() - 1) * th;
        var pw = tw + th + dot * 2;
        var x = (w - pw) / 2;
        panel(dc, x, cy - ph / 2, pw, ph, (th * 7) / 10, Face.UNDERLAY);
        dc.setColor(Face.ALERT_DOT, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(x + (th * 7) / 10, cy - ((lines.size() - 1) * th) / 2, dot);
        dc.setColor(Face.ALERT, Graphics.COLOR_TRANSPARENT);
        for (var j = 0; j < lines.size(); j++) {
            var ly = cy + (j * 2 - (lines.size() - 1)) * th / 2;
            dc.drawText(x + (th * 7) / 10 + dot * 2, ly, font, lines[j], Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        }
    }

    // The one control, and a tick at the enter key so a button press reads as the same act.
    function control(dc as Graphics.Dc, kind as Number, cy as Number) as Void {
        if (kind == Face.CONTROL_NONE) {
            return;
        }
        var w = dc.getWidth();
        var h = dc.getHeight();
        var font = (kind == Face.CONTROL_CONFIRM || kind == Face.CONTROL_LINK) ? Graphics.FONT_XTINY : Graphics.FONT_SMALL;
        var label = Face.str(kind == Face.CONTROL_START ? Rez.Strings.Start
            : (kind == Face.CONTROL_STOP ? Rez.Strings.Stop : (kind == Face.CONTROL_CONFIRM ? Rez.Strings.PressAgainToStop
            : (kind == Face.CONTROL_LINK ? Rez.Strings.OpenOnPhone : Rez.Strings.Details))));
        var th = dc.getFontHeight(font);
        var bh = (dc.getFontHeight(Graphics.FONT_SMALL) * 17) / 10;
        var bw = textWidth(dc, label, font) + th * 2;
        var minW = (w * 46) / 100;
        if (bw < minW) {
            bw = minW;
        }
        var bright = kind == Face.CONTROL_START || kind == Face.CONTROL_LINK;
        var fill = bright ? Face.ORANGE : Face.UNDERLAY;
        var ink = bright ? Face.INK : Face.CREAM;
        roundRect(dc, (w - bw) / 2, cy - bh / 2, bw, bh, fill);
        if (kind == Face.CONTROL_CONFIRM) {
            dc.setColor(Face.CREAM, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(2);
            dc.drawRoundedRectangle((w - bw) / 2, cy - bh / 2, bw, bh, bh / 2);
            dc.setPenWidth(1);
        }
        dc.setColor(ink, Graphics.COLOR_TRANSPARENT);
        dc.drawText(w / 2, cy, font, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        // The enter key: about two o'clock on round watches, the upper right edge on the rectangle.
        var tick = bright ? Face.ORANGE : Face.CREAM;
        dc.setColor(tick, Graphics.COLOR_TRANSPARENT);
        if (Face.isRect(dc)) {
            dc.fillRoundedRectangle(w - 6, (h * 20) / 100, 6, (h * 10) / 100, 3);
        } else {
            dc.setPenWidth(w / 60 + 2);
            dc.drawArc(w / 2, h / 2, w / 2 - w / 90 - 2, Graphics.ARC_COUNTER_CLOCKWISE, 22, 38);
            dc.setPenWidth(1);
        }
    }

    function first(dc as Graphics.Dc, f as FaceFacts) as Void {
        var h = dc.getHeight();
        var w = dc.getWidth();
        var p = f.pill();
        if (p != null) {
            pill(dc, p, (h * 32) / 100);
        }
        var kind = f.control();
        if (kind == Face.CONTROL_NONE) {
            // Opened in a way Garmin closes after about two minutes: say so under the pill.
            var font = Graphics.FONT_XTINY;
            var lh = dc.getFontHeight(font);
            var top = (h * 46) / 100;
            var pad = lh / 2;
            panel(dc, (w * 10) / 100, top - pad, (w * 80) / 100, lh * 4 + pad * 2, lh, Face.UNDERLAY);
            block(dc, Face.str(Rez.Strings.TimeoutPanel), font, Face.CREAM, top, top + lh * 4, w / 8);
            return;
        }
        control(dc, kind, (h * 66) / 100);
    }

    // One fact as a centred line: the label quiet, the value bright.
    function row(dc as Graphics.Dc, label as String, value as String, y as Number) as Void {
        var font = Graphics.FONT_XTINY;
        var gap = dc.getFontHeight(font) / 3;
        var lw = textWidth(dc, label, font);
        var vw = textWidth(dc, value, font);
        var x = (dc.getWidth() - lw - gap - vw) / 2;
        dc.setColor(Face.CALM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, font, label, Graphics.TEXT_JUSTIFY_LEFT);
        dc.setColor(Face.CREAM, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x + lw + gap, y, font, value, Graphics.TEXT_JUSTIFY_LEFT);
    }

    // Below the fold: the time running, what waits on the watch, the phone, the next step.
    function details(dc as Graphics.Dc, f as FaceFacts) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var rect = Face.isRect(dc);
        var inset = rect ? w / 14 : w / 9;
        var top = rect ? h / 12 : h / 11;
        panel(dc, inset / 2, top, w - inset, h - top * 2, h / 10, Face.UNDERLAY);

        var y = top + h / 30;
        var big = Graphics.FONT_MEDIUM;
        var running = f.phase == Face.PHASE_ACTIVE;
        var failed = f.control() == Face.CONTROL_DETAILS || f.reason == Face.REASON_TIMEOUT_LAUNCH;
        var header = running ? Face.elapsedText(f.elapsedSec) : (failed ? f.pill() as String : Face.str(Rez.Strings.Ready));
        dc.setColor(running ? Face.CREAM : (failed ? Face.ALERT : Face.CALM), Graphics.COLOR_TRANSPARENT);
        var hf = running ? big : Graphics.FONT_SMALL;
        if (textWidth(dc, header, hf) > (w * 62) / 100) {
            hf = Graphics.FONT_XTINY;
        }
        dc.drawText(w / 2, y, hf, header, Graphics.TEXT_JUSTIFY_CENTER);
        y += dc.getFontHeight(hf);
        if (running) {
            var sub = f.reason == Face.REASON_MIC_STALLED ? Face.str(Rez.Strings.PillMicStalled) : Face.str(Rez.Strings.Running);
            dc.setColor(f.reason == Face.REASON_MIC_STALLED ? Face.ALERT : (Face.isMip() ? 0xFFAA55 : Face.LIVE), Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, y, Graphics.FONT_XTINY, sub, Graphics.TEXT_JUSTIFY_CENTER);
            y += dc.getFontHeight(Graphics.FONT_XTINY);
        }
        y += h / 40;
        // Nothing held and nothing running: the row would only say zero.
        if (f.engaged() || f.heldSec != 0) {
            row(dc, Face.str(Rez.Strings.HeldOnWatch), f.heldText(), y);
            y += (dc.getFontHeight(Graphics.FONT_XTINY) * 11) / 10;
        }
        row(dc, Face.str(Rez.Strings.PhoneCheckedIn), f.phoneText(), y);
        y += (dc.getFontHeight(Graphics.FONT_XTINY) * 13) / 10;

        var lines = [] as Array<String>;
        var link = f.phoneAgoSec == -1 && !f.engaged();
        // With the open-on-your-phone button below, the step needs only its first sentence.
        var step = link && f.reason == Face.REASON_NO_PHONE ? Face.str(Rez.Strings.StepNoPhoneLink) : f.nextStep();
        if (step != null) {
            lines.add(step);
        }
        if (step == null) {
            lines.add(f.engaged() ? Face.str(Rez.Strings.HopLine) : Face.fmt(Rez.Strings.HoldsAbout, (f.capSec / 60).toString()));
        }
        var text = "";
        for (var i = 0; i < lines.size(); i++) {
            text += (i > 0 ? "\n" : "") + lines[i];
        }
        var bottom = h - top;
        if (link) {
            var bh = (dc.getFontHeight(Graphics.FONT_SMALL) * 17) / 10;
            bottom = h - top - bh - h / 30;
        }
        block(dc, text, Graphics.FONT_XTINY, Face.CALM, y, bottom, inset / 2 + w / 30);
        if (link) {
            control(dc, Face.CONTROL_LINK, h - top - (dc.getFontHeight(Graphics.FONT_SMALL) * 17) / 20 - h / 40);
        }
    }
}
