// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// Minimal stand-in glance view (replaced by the design pass).
// Reads K_FACE read-only so the glance VM stays isolated from foreground capture classes.
(:glance)
class VoiceGlanceView extends WatchUi.GlanceView {
    public function initialize() {
        GlanceView.initialize();
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var label = "solstone";
        var face = VoiceProto.readIntArray(VoiceProto.K_FACE, 4);
        if (face != null && face[0] == VoiceProto.PHASE_ACTIVE) {
            label = "solstone · active";
        }
        dc.drawText(0, dc.getHeight() / 2, Graphics.FONT_GLANCE, label, Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
