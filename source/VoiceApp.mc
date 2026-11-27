// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Featherweight AppBase lifecycle shell (matches Garmin SDK BackgroundTimerApp pattern):
// Keeps initialize()/onStart() near-zero bytes so the 64 KB Background VM never allocates or loads FG classes!
(:background)
class VoiceApp extends Application.AppBase {
    private var _ctrl as VoiceController?;
    private var _timeoutLaunch as Boolean = false;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        if (state != null) {
            if (state[:launchedFromGlance] == true || state[:launchedFromComplication] != null) {
                _timeoutLaunch = true;
            }
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var ctrl = $.createVoiceController(_timeoutLaunch);
        _ctrl = ctrl;
        return $.buildInitialView(ctrl);
    }

    public function getServiceDelegate() as [System.ServiceDelegate] {
        return [new $.VoiceBgService()];
    }

    public function onStop(state as Dictionary?) as Void {
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.shutdownVoiceController(ctrl);
            _ctrl = null;
        }
    }

    public function onBackgroundData(data as Application.PersistableType) as Void {
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.dispatchBgData(ctrl, data);
        }
    }

    public function onStorageChanged() as Void {
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.dispatchStorageChanged(ctrl);
        }
    }

    public function onDisplayModeChanged() as Void {
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.dispatchDisplayModeChanged(ctrl);
        }
    }

    public function onActive(state as Dictionary?) as Void {
    }

    public function onInactive(state as Dictionary?) as Void {
    }
}

// Foreground-only bridge functions (excluded from 64 KB background VM; official Garmin SDK pattern)
(:typecheck(disableBackgroundCheck))
function createVoiceController(timeoutLaunch as Boolean) as VoiceController {
    return new $.VoiceController(timeoutLaunch);
}

(:typecheck(disableBackgroundCheck))
function buildInitialView(ctrl as VoiceController) as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
    return ctrl.createInitialView();
}

(:typecheck(disableBackgroundCheck))
function shutdownVoiceController(ctrl as VoiceController) as Void {
    ctrl.shutdown();
}

(:typecheck(disableBackgroundCheck))
function dispatchBgData(ctrl as VoiceController, data as Application.PersistableType) as Void {
    ctrl.onBackgroundData(data);
}

(:typecheck(disableBackgroundCheck))
function dispatchStorageChanged(ctrl as VoiceController) as Void {
    ctrl.onStorageChanged();
}

(:typecheck(disableBackgroundCheck))
function dispatchDisplayModeChanged(ctrl as VoiceController) as Void {
    ctrl.onDisplayModeChanged();
}
