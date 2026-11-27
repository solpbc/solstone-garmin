// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Complications;
import Toybox.Lang;
import Toybox.Time;

// The complication a watch face can show: the sun icon and one short value. The value is the
// state, so it is never a stale "on": the app publishes on every transition and on stop, and a
// background wake that finds the foreground gone publishes from what was stored.
(:background)
module ComplicationState {
    enum Value {
        VALUE_UNKNOWN = 0,
        VALUE_OFF = 1,
        VALUE_ON = 2,
        VALUE_ATTENTION = 3
    }

    var _last as Number = -1;

    function publish(v as Number) as Void {
        if (v == _last || !(Toybox has :Complications)) {
            return;
        }
        var id = Rez.Strings.ComplicationUnknown;
        if (v == VALUE_ON) {
            id = Rez.Strings.ComplicationOn;
        } else if (v == VALUE_OFF) {
            id = Rez.Strings.ComplicationOff;
        } else if (v == VALUE_ATTENTION) {
            id = Rez.Strings.ComplicationAttention;
        }
        try {
            Complications.updateComplication(0, { :value => Application.loadResource(id) as String });
            _last = v;
        } catch (e) {
        }
    }

    // What the stored state says, for callers that can't see the live session: a session the
    // foreground hasn't touched for staleSec is not shown as running.
    function fromStorage(staleSec as Number) as Number {
        var face = VoiceProto.readIntArray(VoiceProto.K_FACE, 4);
        if (face == null) {
            return VALUE_UNKNOWN;
        }
        if (face[0] != VoiceProto.PHASE_READY) {
            var fg = VoiceProto.readIntArray(VoiceProto.K_FG_META, 7);
            if (fg != null && fg[2] == 1 && (Time.now().value() - fg[6]) < staleSec) {
                return VALUE_ON;
            }
            return VALUE_UNKNOWN;
        }
        var end = face[2];
        if (end == VoiceProto.END_STORAGE_FULL || end == VoiceProto.END_MIC_DENIED
                || end == VoiceProto.END_MIC_ERROR || end == VoiceProto.END_UNEXPECTED) {
            return VALUE_ATTENTION;
        }
        return VALUE_OFF;
    }
}
