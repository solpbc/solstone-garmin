// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

// The sun, all day: the face's decorative sky. It reads only the clock and a
// time-zone reference point the paired phone shares; it never asks the watch
// for a position. Without a point it uses 06:30 / 19:30.
module SunArc {
    const PHI = 1.6180339887f;
    const GOLD = 0xFFCC33;
    const ORANGE = 0xE8913A;

    enum Style {
        STYLE_FULL = 0,     // AMOLED, display on: the full sky over black
        STYLE_OUTLINE = 1,  // MIP always-on: the sun's outline in one warm ink
        STYLE_DIM = 2       // AMOLED low power: a grey outline, nothing else
    }

    // [t, night, envelope, weight, extended, twilight, minute, rise, set]
    typedef Frame as Array<Float>;

    function wrap(x as Numeric, n as Numeric) as Float {
        var xf = x.toFloat();
        var nf = n.toFloat();
        return (xf - nf * Math.floor(xf / nf)).toFloat();
    }

    function clamp(x as Numeric, lo as Numeric, hi as Numeric) as Float {
        var v = x.toFloat();
        return v < lo ? lo.toFloat() : (v > hi ? hi.toFloat() : v);
    }

    // Sunrise and sunset in local minutes for a day of the year, or null in polar day or night.
    function solar(n as Float, offsetMin as Float, lat as Float, lon as Float) as Array<Float>? {
        var rise = crossing(n, offsetMin, lat, lon, true);
        var set = crossing(n, offsetMin, lat, lon, false);
        if (rise == null || set == null) {
            return null;
        }
        if (set < rise) {
            set += 1440.0f;
        }
        return [rise, set];
    }

    function crossing(n as Float, offsetMin as Float, lat as Float, lon as Float, rising as Boolean) as Float? {
        var t = n + ((rising ? 6.0f : 18.0f) - lon / 15.0f) / 24.0f;
        var m = 0.9856f * t - 3.289f;
        var mr = Math.toRadians(m);
        var l = wrap(m + 1.916f * Math.sin(mr) + 0.020f * Math.sin(2 * mr) + 282.634f, 360.0f);
        var lr = Math.toRadians(l);
        var ra = wrap(Math.toDegrees(Math.atan(0.91764f * Math.tan(lr))).toFloat(), 360.0f);
        ra = (ra + Math.floor(l / 90.0f) * 90.0f - Math.floor(ra / 90.0f) * 90.0f) / 15.0f;
        var sd = 0.39782f * Math.sin(lr);
        var cd = Math.cos(Math.asin(sd));
        var latr = Math.toRadians(lat);
        var ch = (Math.cos(Math.toRadians(90.833f)) - sd * Math.sin(latr)) / (cd * Math.cos(latr));
        if (ch < -1.0f || ch > 1.0f) {
            return null;
        }
        var acosDeg = Math.toDegrees(Math.acos(ch)).toFloat();
        var ha = (rising ? 360.0f - acosDeg : acosDeg) / 15.0f;
        return wrap(wrap((ha + ra - 0.06571f * t - 6.622f - lon / 15.0f).toFloat(), 24.0f) * 60.0f + offsetMin, 1440.0f);
    }

    function dayOfYear(info as Gregorian.Info) as Number {
        var days = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
        var month = info.month as Number;
        var year = info.year as Number;
        var doy = days[month - 1] + (info.day as Number);
        var leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;
        if (leap && month > 2) {
            doy += 1;
        }
        return doy;
    }

    // Walks back to the most recent day that has a sunrise and a sunset (polar day and night).
    function solarPair(point as Array<Number>?, offsetOverride as Float?) as Array<Float> {
        if (point == null) {
            return [390.0f, 1170.0f];
        }
        var lat = (point[0] as Number) / 100.0f;
        var lon = (point[1] as Number) / 100.0f;
        var info = Gregorian.info(Time.now(), Time.FORMAT_SHORT);
        var doy = dayOfYear(info);
        var offset = offsetOverride != null ? offsetOverride : System.getClockTime().timeZoneOffset / 60.0f;
        for (var back = 0; back < 184; back++) {
            var d = doy - back;
            if (d < 1) {
                d += 365;
            }
            var pair = solar(d.toFloat(), offset, lat, lon);
            if (pair != null) {
                return pair;
            }
        }
        return [390.0f, 1170.0f];
    }

    function frame(minute as Float, rise as Float, rawSet as Float) as Frame {
        var set = rawSet < rise ? rawSet + 1440.0f : rawSet;
        var dawn = rise - 30.0f;
        var dusk = set + 30.0f;
        var m = minute;
        if (dusk > 1440.0f && minute < dusk - 1440.0f) {
            m = minute + 1440.0f;
        } else if (dawn < 0.0f && minute >= dawn + 1440.0f) {
            m = minute - 1440.0f;
        }
        var t = (m - dawn) / (dusk - dawn);
        var night;
        if (m < dawn) {
            night = 1.0f;
        } else if (m < rise) {
            night = 1.0f - (m - dawn) / 30.0f;
        } else if (m <= set) {
            night = 0.0f;
        } else if (m < dusk) {
            night = (m - set) / 30.0f;
        } else {
            night = 1.0f;
        }
        var u = clamp(t, 0.0f, 1.0f);
        var envelope = 1.0f;
        if (u < 0.22f) {
            envelope = Math.sin(u / 0.22f * Math.PI / 2).toFloat();
        } else if (u > 0.78f) {
            envelope = Math.sin((1.0f - u) / 0.22f * Math.PI / 2).toFloat();
        }
        var weight = 1.0f - envelope;
        var extended = t;
        var twilight = 0.0f;
        if (m < dawn || m > dusk) {
            var span = wrap(dawn - dusk, 1440.0f);
            var ms = wrap(m - dusk, 1440.0f);
            var mid = span / 2.0f;
            var half = clamp(span - 120.0f, 0.0f, 180.0f) / 2.0f;
            var from = mid - half;
            var to = mid + half;
            if (ms <= from && from > 0) {
                twilight = ms / from;
                weight = Math.pow(clamp(1.0f - twilight * twilight, 0.0f, 1.0f), 1.5f).toFloat();
                extended = 1.0f + 0.1f * twilight;
            } else if (ms >= to && span > to) {
                twilight = (span - ms) / (span - to);
                weight = Math.pow(clamp(1.0f - twilight * twilight, 0.0f, 1.0f), 1.5f).toFloat();
                extended = -0.1f * twilight;
            } else {
                weight = 0.0f;
                extended = ms < mid ? 1.1f : -0.1f;
                twilight = 1.0f;
            }
        }
        return [t, night, envelope, weight, extended, twilight, m, rise, set];
    }

    function scale(rgb as Number, a as Numeric) as Number {
        var k = clamp(a, 0.0f, 1.0f);
        var r = ((rgb >> 16) & 0xFF) * k;
        var g = ((rgb >> 8) & 0xFF) * k;
        var b = (rgb & 0xFF) * k;
        return (r.toNumber() << 16) | (g.toNumber() << 8) | b.toNumber();
    }

    // Source-over of rgb at alpha a onto an opaque base.
    function over(base as Number, rgb as Number, a as Numeric) as Number {
        var k = clamp(a, 0.0f, 1.0f);
        var r = ((base >> 16) & 0xFF) * (1 - k) + ((rgb >> 16) & 0xFF) * k;
        var g = ((base >> 8) & 0xFF) * (1 - k) + ((rgb >> 8) & 0xFF) * k;
        var b = (base & 0xFF) * (1 - k) + (rgb & 0xFF) * k;
        return (r.toNumber() << 16) | (g.toNumber() << 8) | b.toNumber();
    }

    function lin(v as Number) as Float {
        var c = v / 255.0f;
        return c <= 0.04045f ? c / 12.92f : Math.pow((c + 0.055f) / 1.055f, 2.4f).toFloat();
    }

    function toLab(rgb as Number) as Array<Float> {
        var r = lin((rgb >> 16) & 0xFF);
        var g = lin((rgb >> 8) & 0xFF);
        var b = lin(rgb & 0xFF);
        var l = Math.pow(0.4122214708f * r + 0.5363325363f * g + 0.0514459929f * b, 1.0f / 3).toFloat();
        var m = Math.pow(0.2119034982f * r + 0.6806995451f * g + 0.1073969566f * b, 1.0f / 3).toFloat();
        var s = Math.pow(0.0883024619f * r + 0.2817188376f * g + 0.6299787005f * b, 1.0f / 3).toFloat();
        return [0.2104542553f * l + 0.7936177850f * m - 0.0040720468f * s,
                1.9779984951f * l - 2.4285922050f * m + 0.4505937099f * s,
                0.0259040371f * l + 0.7827717662f * m - 0.8086757660f * s];
    }

    function channel(v as Float) as Number {
        var c = v <= 0.0031308f ? v * 12.92f : 1.055f * Math.pow(v > 0 ? v : 0.0f, 1 / 2.4f) - 0.055f;
        var n = (c * 255 + 0.5f).toNumber();
        return n < 0 ? 0 : (n > 255 ? 255 : n);
    }

    // The twilight glow's colour: gold toward sol orange in OKLab as the evening deepens.
    function goldToOrange(f as Float) as Number {
        var t = clamp(f, 0.0f, 1.0f);
        var a = toLab(GOLD);
        var b = toLab(ORANGE);
        var c0 = a[0] + (b[0] - a[0]) * t;
        var c1 = a[1] + (b[1] - a[1]) * t;
        var c2 = a[2] + (b[2] - a[2]) * t;
        var l = Math.pow(c0 + 0.3963377774f * c1 + 0.2158037573f * c2, 3).toFloat();
        var m = Math.pow(c0 - 0.1055613458f * c1 - 0.0638541728f * c2, 3).toFloat();
        var s = Math.pow(c0 - 0.0894841775f * c1 - 1.2914855480f * c2, 3).toFloat();
        return (channel(4.0767416621f * l - 3.3077115913f * m + 0.2309699292f * s) << 16)
            | (channel(-1.2684380046f * l + 2.6097574011f * m - 0.3413193965f * s) << 8)
            | channel(-0.0041960863f * l - 0.7034186147f * m + 1.7076147010f * s);
    }

    // The arc a sun travels on a w×h screen: [ox, oy, arcRadius, startAngle, sweep, sunRadius].
    function scene(w as Number, h as Number) as Array<Float> {
        var mn = (w < h ? w : h).toFloat();
        var radius = PHI * mn / 2;
        var d = radius / Math.sqrt(2).toFloat();
        var dx = w + 2 * d;
        var dy = h + 2 * d;
        var chord = Math.sqrt(dx * dx + dy * dy).toFloat();
        var sag = (Math.tan(Math.PI / 20) / 2 * chord).toFloat();
        var arc = chord * chord / (8 * sag) + sag / 2;
        var ox = w / 2.0f - dy / chord * (arc - sag);
        var oy = h / 2.0f + dx / chord * (arc - sag);
        var a = Math.atan2(-d - oy, -d - ox).toFloat();
        var delta = Math.atan2(h + d - oy, w + d - ox).toFloat() - a;
        while (delta > Math.PI) {
            delta -= 2 * Math.PI;
        }
        while (delta < -Math.PI) {
            delta += 2 * Math.PI;
        }
        return [ox, oy, arc, a, delta.toFloat(), radius];
    }

    function pointAt(sc as Array<Float>, t as Float) as Array<Float> {
        var ang = sc[3] + sc[4] * t;
        return [sc[0] + sc[2] * Math.cos(ang).toFloat(), sc[1] + sc[2] * Math.sin(ang).toFloat()];
    }

    // A radial glow as stepped rings over black: a -> 0.45a -> 0 at 0 / 38% / 100% of r.
    function glow(dc as Graphics.Dc, x as Float, y as Float, r as Float, a as Float, rgb as Number) as Void {
        if (a < 0.004f) {
            return;
        }
        var steps = 14;
        for (var i = 0; i < steps; i++) {
            var v = 1.0f - i.toFloat() / steps;
            var va = v <= 0.38f ? a * (1 - 0.55f * v / 0.38f) : a * 0.45f * (1 - (v - 0.38f) / 0.62f);
            var vn = 1.0f - (i + 1).toFloat() / steps;
            var inner = vn <= 0.38f ? a * (1 - 0.55f * vn / 0.38f) : a * 0.45f * (1 - (vn - 0.38f) / 0.62f);
            dc.setColor(scale(rgb, (va + inner) / 2), Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(x.toNumber(), y.toNumber(), (r * v).toNumber());
        }
    }

    // The mark: ten beams on a base circle around a ring, tip radius r.
    function beamPoints(cx as Float, cy as Float, r as Float, k as Number) as Array<[Numeric, Numeric]> {
        var s = r / 13.5f;
        var base = 8.5f + 1 / PHI;
        var half = Math.toRadians(16.5f);
        var bx = base * Math.sin(half);
        var by = -base * Math.cos(half);
        var pts = [] as Array<[Numeric, Numeric]>;
        var rot = Math.toRadians(36.0f * k);
        var cr = Math.cos(rot);
        var sr = Math.sin(rot);
        // tip -> right base along a slightly bowed edge, base arc, left base -> tip
        var raw = [] as Array<Array<Float>>;
        raw.add([0.0f, -13.5f]);
        for (var i = 1; i <= 4; i++) {
            var f = i / 4.0f;
            raw.add([(bx * f).toFloat(), (-13.5f + (by + 13.5f) * f).toFloat()]);
        }
        for (var j = 1; j < 4; j++) {
            var ang = -Math.PI / 2 + half - (2 * half) * j / 4.0f;
            raw.add([(base * Math.cos(ang)).toFloat(), (base * Math.sin(ang)).toFloat()]);
        }
        for (var i2 = 4; i2 >= 1; i2--) {
            var f2 = i2 / 4.0f;
            raw.add([(-bx * f2).toFloat(), (-13.5f + (by + 13.5f) * f2).toFloat()]);
        }
        for (var p = 0; p < raw.size(); p++) {
            var x = raw[p][0] * s;
            var y = raw[p][1] * s;
            pts.add([(cx + x * cr - y * sr).toNumber(), (cy + x * sr + y * cr).toNumber()]);
        }
        return pts;
    }

    function drawSun(dc as Graphics.Dc, cx as Float, cy as Float, r as Float, beam as Number, ring as Number, outline as Boolean) as Void {
        for (var k = 0; k < 10; k++) {
            var pts = beamPoints(cx, cy, r, k);
            dc.setColor(beam, Graphics.COLOR_TRANSPARENT);
            if (outline) {
                for (var i = 0; i < pts.size(); i++) {
                    var a = pts[i];
                    var b = pts[(i + 1) % pts.size()];
                    dc.drawLine(a[0], a[1], b[0], b[1]);
                }
            } else {
                dc.fillPolygon(pts);
            }
        }
        var s = r / 13.5f;
        dc.setColor(ring, Graphics.COLOR_TRANSPARENT);
        var pen = ((2 / PHI + 0.5f) * s).toNumber();
        dc.setPenWidth(outline ? 2 : (pen < 1 ? 1 : pen));
        dc.drawCircle(cx.toNumber(), cy.toNumber(), (6.5f * s).toNumber());
        dc.setPenWidth(1);
    }

    function smooth(x as Float) as Float {
        var v = clamp(x, 0.0f, 1.0f);
        return v * v * (3 - 2 * v);
    }

    // The mark's ten points as a night constellation around the arc's midpoint.
    function drawConstellation(dc as Graphics.Dc, sc as Array<Float>, f as Frame, w as Number, h as Number, ink as Number?) as Void {
        var visibility = clamp(f[1] * (1 - 0.62f * f[3]), 0.0f, 1.0f);
        var cv = smooth((visibility - 0.3f) / 0.35f);
        if (cv < 0.01f) {
            return;
        }
        var dusk = f[8] + 30;
        var dawn = f[7] - 30;
        var span = wrap(dawn - dusk, 1440.0f);
        var elapsed = wrap(f[6] - dusk, 1440.0f);
        var u = elapsed <= span ? elapsed / span : (f[0] < 0 ? 0.0f : 1.0f);
        var angle = sc[4] * (u - 0.5f);
        var centre = pointAt(sc, 0.5f);
        var k = (w < h ? w : h) / 227.0f;
        var levels = [0, 1, 0, 0, 1, 0, 0, 1, 0, 1];
        for (var i = 0; i < 10; i++) {
            var q = Math.toRadians(-90.0f + 36 * i);
            var px = centre[0] + sc[5] / PHI * Math.cos(q);
            var py = centre[1] + sc[5] / PHI * Math.sin(q);
            var rx = sc[0] + (px - sc[0]) * Math.cos(angle) - (py - sc[1]) * Math.sin(angle);
            var ry = sc[1] + (px - sc[0]) * Math.sin(angle) + (py - sc[1]) * Math.cos(angle);
            if (rx < -3 || ry < -3 || rx > w + 3 || ry > h + 3) {
                continue;
            }
            var level = levels[i];
            var op = Math.pow(PHI, -0.75f * level) * 0.92f * 1.25f;
            op = (op > 1 ? 1.0f : op) * cv;
            var rr = (1.75f * Math.pow(PHI, -0.5f * level) * 1.35f + 0.4f) * 0.8f * k;
            if (ink != null) {
                dc.setColor(ink, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(rx.toNumber(), ry.toNumber(), rr < 2 ? 2 : rr.toNumber());
            } else {
                dc.setColor(scale(GOLD, op * 0.14f), Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(rx.toNumber(), ry.toNumber(), (rr * 4.2f).toNumber());
                dc.setColor(scale(GOLD, op), Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(rx.toNumber(), ry.toNumber(), rr < 1 ? 1 : rr.toNumber());
            }
        }
    }

    function nowMinute() as Float {
        var c = System.getClockTime();
        return (c.hour * 60 + c.min).toFloat();
    }

    // Draws the whole background. minute and pair let a caller pin the clock.
    function draw(dc as Graphics.Dc, style as Style, minute as Float, pair as Array<Float>) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(style == STYLE_FULL);
        }
        var sc = scene(w, h);
        var f = frame(minute, pair[0], pair[1]);
        var t = f[0];
        var night = f[1];
        var env = f[2];
        var p = pointAt(sc, clamp(t, 0.0f, 1.0f));
        var up = t > -0.02f && t < 1.02f;
        if (style == STYLE_FULL) {
            if (f[3] > 0.001f) {
                var q = pointAt(sc, f[4]);
                glow(dc, q[0], q[1], sc[5] * PHI * PHI, 0.62f * f[3], goldToOrange(0.3f + 0.5f * f[5]));
            }
            var dayA = 0.22f * env * (1 - night);
            if (night < 1 && up) {
                glow(dc, p[0], p[1], sc[5] * PHI, dayA, GOLD);
            }
            drawConstellation(dc, sc, f, w, h, null);
            if (up) {
                var a = 0.2f * env * (1 - night);
                var under = (night < 1) ? scale(GOLD, dayA) : 0;
                drawSun(dc, p[0], p[1], sc[5], over(under, GOLD, a), over(under, ORANGE, a), false);
            }
        } else {
            var ink = style == STYLE_OUTLINE ? 0xAA5500 : 0x555555;
            if (up && night < 1) {
                drawSun(dc, p[0], p[1], sc[5], ink, ink, true);
            } else if (style == STYLE_OUTLINE) {
                drawConstellation(dc, sc, f, w, h, ink);
            }
        }
    }
}
