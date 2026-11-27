// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// Featherweight AppBase lifecycle shell:
// Keeps initialize()/onStart() near-zero bytes so the 64 KB Background and Glance VMs stay lean.
(:background :glance)
class VoiceApp extends Application.AppBase {
    private var _ctrl as VoiceController?;
    private var _launchBlockReason as Number = VoiceProto.LAUNCH_OK;

    public function initialize() {
        AppBase.initialize();
    }

    public function onStart(state as Dictionary?) as Void {
        _launchBlockReason = VoiceProto.LAUNCH_OK;
        if (state != null) {
            if (state[:launchedFromGlance] == true) {
                _launchBlockReason = VoiceProto.LAUNCH_FROM_GLANCE;
            } else if (state[:launchedFromComplication] != null) {
                _launchBlockReason = VoiceProto.LAUNCH_FROM_COMPLICATION;
            } else if (state[:launchedFromPostInstall] != null) {
                _launchBlockReason = VoiceProto.LAUNCH_FROM_POST_INSTALL;
            }
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var ctrl = $.createVoiceController(_launchBlockReason);
        _ctrl = ctrl;
        return $.buildInitialView(ctrl);
    }

    (:glance :typecheck(disableBackgroundCheck))
    public function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new $.VoiceGlanceView()];
    }

    (:typecheck(disableGlanceCheck))
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
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.dispatchAppActive(ctrl);
        }
    }

    public function onInactive(state as Dictionary?) as Void {
        var ctrl = _ctrl;
        if (ctrl != null) {
            $.dispatchAppInactive(ctrl);
        }
    }
}

// Foreground-only bridge functions (excluded from 64 KB background and glance VMs)
(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function createVoiceController(launchBlockReason as Number) as VoiceController {
    return new $.VoiceController(launchBlockReason);
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function buildInitialView(ctrl as VoiceController) as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
    return ctrl.createInitialView();
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function shutdownVoiceController(ctrl as VoiceController) as Void {
    ctrl.shutdown();
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function dispatchBgData(ctrl as VoiceController, data as Application.PersistableType) as Void {
    ctrl.onBackgroundData(data);
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function dispatchStorageChanged(ctrl as VoiceController) as Void {
    ctrl.onStorageChanged();
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function dispatchDisplayModeChanged(ctrl as VoiceController) as Void {
    ctrl.onDisplayModeChanged();
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function dispatchAppActive(ctrl as VoiceController) as Void {
    ctrl.onAppActive();
}

(:typecheck([disableBackgroundCheck, disableGlanceCheck]))
function dispatchAppInactive(ctrl as VoiceController) as Void {
    ctrl.onAppInactive();
}
