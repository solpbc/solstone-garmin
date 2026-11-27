// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Audio;
import Toybox.Audio.Capture;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Tiny 3-method ISR-minimal Capture.Callbacks object — ZERO back-reference to app/controller,
// ZERO Storage I/O, ZERO BLE calls, ZERO Capture.* calls, ZERO allocations.
class VoiceCaptureCallbacks {
    private const CAP as Number = 32; // Power-of-2 ring (~16s of 500ms Opus chunks in RAM)
    public var ring as Array<ByteArray?>;
    public var rIdx as Number = 0;
    public var wIdx as Number = 0;
    public var dropped as Number = 0;
    public var completeFlag as Boolean = false;
    public var errFlag as Boolean = false;
    public var lastErr as Number = -1;

    public function initialize() {
        ring = new Array<ByteArray?>[CAP];
    }

    public function onData(audioData as ByteArray) as Void {
        try {
            var next = (wIdx + 1) & 31;
            if (next != rIdx) {
                ring[wIdx] = audioData;
                wIdx = next;
            } else {
                dropped++;
            }
        } catch (_) {}
    }

    public function onComplete() as Void {
        completeFlag = true;
    }

    public function onError(error as Capture.Error) as Void {
        lastErr = error as Number;
        errFlag = true;
    }

    public function pop() as ByteArray? {
        if (rIdx == wIdx) {
            return null;
        }
        var item = ring[rIdx];
        ring[rIdx] = null;
        rIdx = (rIdx + 1) & 31;
        return item;
    }

    public function resetFlags() as Void {
        completeFlag = false;
        errFlag = false;
        lastErr = -1;
    }
}

// Timer-driven capture controller: initializes Audio.Capture ONCE per session and cycles only
// start()/stop() across 5-minute segments (never calling Capture.* inside any callback).
class VoiceCaptureEngine {
    public enum CapState {
        CAP_IDLE,
        CAP_RUNNING,
        CAP_STOPPING,
        CAP_SETTLING,
        CAP_INTERRUPTED
    }

    private const STALL_TIMEOUT_MS as Number = 45000; // < 60s attention bound, > 20s flash pause margin
    private const SETTLE_MS as Number = 300;
    private const STOP_TIMEOUT_MS as Number = 3000;
    private const INTERRUPT_RETRY_MS as Number = 2000;

    private var _cb as VoiceCaptureCallbacks;
    private var _state as CapState = CAP_IDLE;
    private var _initialized as Boolean = false;
    private var _rateKhz as Number = 16;

    private var _segId as Number = 0;
    private var _segEpoch as Number = 0;
    private var _tzOffsetMin as Number = 0;
    private var _segStartMs as Number = 0;
    private var _segHasFirstChunk as Boolean = false;
    private var _lastChunkMs as Number = 0;
    private var _stateMs as Number = 0;
    private var _stalled as Boolean = false;
    private var _interrupted as Boolean = false;
    private var _segRecoveryDone as Boolean = false;
    private var _segsCompleted as Number = 0;
    private var _wantStopAll as Boolean = false;
    private var _stopEndReason as Number = VoiceProto.END_NONE;
    private var _lastFailureErr as Number = -1;

    public function initialize() {
        _cb = new VoiceCaptureCallbacks();
    }

    public function getState() as CapState { return _state; }
    public function isRecording() as Boolean { return _state != CAP_IDLE; }
    public function hasLiveAudio() as Boolean {
        return (_state == CAP_RUNNING) && _segHasFirstChunk && !_stalled && !_interrupted;
    }
    public function isStarting() as Boolean {
        return (_state == CAP_RUNNING) && !_segHasFirstChunk && !_stalled && !_interrupted;
    }
    public function isInterrupted() as Boolean { return _interrupted; }
    public function isStalled() as Boolean { return _stalled; }
    public function segId() as Number { return _segId; }
    public function segEpoch() as Number { return _segEpoch; }
    public function tzOffsetMin() as Number { return _tzOffsetMin; }
    public function segsCompleted() as Number { return _segsCompleted; }
    public function droppedChunks() as Number { return _cb.dropped; }
    public function lastError() as Number { return _lastFailureErr; }
    public function stopEndReason() as Number { return _stopEndReason; }
    public function rateKhz() as Number { return _rateKhz; }

    public function segElapsedMs() as Number {
        if (_segStartMs == 0) {
            return 0;
        }
        var dt = System.getTimer() - _segStartMs;
        return (dt > 0) ? dt : 0;
    }

    public function startSession(startSegId as Number) as Boolean {
        _segId = startSegId;
        _wantStopAll = false;
        _stalled = false;
        _interrupted = false;
        _stopEndReason = VoiceProto.END_NONE;
        _lastFailureErr = -1;
        return beginSegment();
    }

    public function stopSession(reason as Number) as Void {
        _wantStopAll = true;
        _interrupted = false;
        if (_stopEndReason == VoiceProto.END_NONE) {
            _stopEndReason = reason;
        }
        if (_state == CAP_RUNNING) {
            requestStopCapture();
        } else if (_state != CAP_STOPPING) {
            _state = CAP_IDLE;
        }
    }

    public function forceStopImmediate() as Void {
        _wantStopAll = true;
        _interrupted = false;
        try {
            if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
                Capture.stop();
            }
        } catch (_) {}
        _state = CAP_IDLE;
    }

    // Temporary OS overlay interruption (notification, alarm, call): keep active intent and recover on return
    public function onAppInactive() as Void {
        if (_state == CAP_RUNNING) {
            _interrupted = true;
        }
    }

    public function onAppActive() as Void {
        if (_state == CAP_INTERRUPTED && !_wantStopAll) {
            _segId++;
            if (beginSegment()) {
                _interrupted = false;
            }
        }
    }

    private function captureLocalTzOffsetMin() as Number {
        try {
            var clk = System.getClockTime();
            return clk.timeZoneOffset / 60;
        } catch (_) {}
        return 0;
    }

    private function ensureInitialized() as Boolean {
        if (_initialized && Capture.getState() != Capture.CAPTURE_UNINITIALIZED) {
            return true;
        }
        var filters = [] as Array<Capture.Filter>;
        try {
            var sup = Capture.getSupportedFilters();
            for (var i = 0; i < sup.size(); i++) {
                if (sup[i] == Capture.FILTER_NREC) {
                    filters.add(Capture.FILTER_NREC);
                    break;
                }
            }
        } catch (_) {}

        try {
            Capture.initializeAudioCapture(_cb, {
                :format => {
                    :containerFormat => Audio.CONTAINER_OGG,
                    :codec => Audio.CODEC_OPUS,
                    :frequency => (_rateKhz == 8) ? Audio.FREQ_8_KHZ : Audio.FREQ_16_KHZ,
                    :channels => Audio.CHANNEL_MONO
                },
                :windowSize => 2048,
                :windowFilledBehavior => Capture.WINDOW_FILLED_CONTINUE,
                :filters => filters
            });
            _initialized = true;
            return true;
        } catch (ex) {
            VoiceProto.vlog("SV initAudio err=" + ex.getErrorMessage());
            _initialized = false;
            _stopEndReason = VoiceProto.END_MIC_DENIED;
            return false;
        }
    }

    private function beginSegment() as Boolean {
        if (!ensureInitialized()) {
            _state = CAP_IDLE;
            return false;
        }
        _cb.resetFlags();
        _segHasFirstChunk = false;
        _segRecoveryDone = false;
        _segEpoch = Time.now().value();
        _tzOffsetMin = captureLocalTzOffsetMin();
        _segStartMs = System.getTimer();
        _lastChunkMs = _segStartMs;
        _stalled = false;
        try {
            Capture.start();
            _state = CAP_RUNNING;
            _stateMs = _segStartMs;
            VoiceProto.vlog("SV seg start id=" + _segId + " tzMin=" + _tzOffsetMin);
            return true;
        } catch (ex) {
            VoiceProto.vlog("SV Capture.start err=" + ex.getErrorMessage());
            _initialized = false;
            _stopEndReason = VoiceProto.END_MIC_DENIED;
            _state = CAP_IDLE;
            return false;
        }
    }

    private function requestStopCapture() as Void {
        _state = CAP_STOPPING;
        _stateMs = System.getTimer();
        try {
            if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
                Capture.stop();
            } else {
                _cb.completeFlag = true;
            }
        } catch (_) {
            _cb.completeFlag = true;
        }
    }

    // Master 250ms tick: drains ISR ring into Storage, enforces 5m segment rotation,
    // distinguishes temporary OS interruptions from real capture failures, and runs the 45s stall watchdog.
    // Returns true when a segment just sealed cleanly.
    public function tick(ring as VoiceStorageRing) as Boolean {
        var now = System.getTimer();
        var segJustSealed = false;

        // 1. Drain any buffered chunks from ISR-minimal ring into Storage (bounded to <=8 chunks/tick)
        var drained = 0;
        while (drained < 8) {
            var chunk = _cb.pop();
            if (chunk == null) {
                break;
            }
            drained++;
            // Empty 0-byte chunks must never mark live audio or reset the stall watchdog
            if (chunk.size() == 0) {
                continue;
            }
            _lastChunkMs = now;
            _stalled = false;
            _interrupted = false;
            var isFirst = !_segHasFirstChunk;
            _segHasFirstChunk = true;
            var relMs = now - _segStartMs;
            if (!ring.appendChunk(chunk, _rateKhz, _segId, _segEpoch, _tzOffsetMin, relMs, isFirst)) {
                stopSession(VoiceProto.END_STORAGE_FULL);
                break;
            }
        }

        // 2. State machine transitions (never called inside Capture.Callbacks)
        if (_state == CAP_RUNNING) {
            if (_cb.errFlag) {
                var err = _cb.lastErr;
                _lastFailureErr = err;
                _cb.errFlag = false;
                VoiceProto.vlog("SV cap err=" + err);
                if (err == (Capture.CAPTURE_ERR_BACKGROUNDED as Number)) {
                    // Temporary OS interruption: seal partial prefix, keep session active & interrupted, retry when active
                    ring.flushSegmentTail(_rateKhz, _segId, _segEpoch, _tzOffsetMin, segElapsedMs(), true);
                    _interrupted = true;
                    _state = CAP_INTERRUPTED;
                    _stateMs = now;
                    return false;
                }
                // Fatal capture failure: end session cleanly without auto-retry
                _wantStopAll = true;
                _stopEndReason = VoiceProto.END_MIC_ERROR;
                requestStopCapture();
                return false;
            }
            if ((now - _lastChunkMs) >= STALL_TIMEOUT_MS) {
                _stalled = true;
                if (!_segRecoveryDone) {
                    _segRecoveryDone = true;
                    VoiceProto.vlog("SV stall recovery seg=" + _segId);
                    requestStopCapture();
                }
                return false;
            }
            if ((now - _segStartMs) >= VoiceProto.SEG_DURATION_MS) {
                requestStopCapture();
                return false;
            }
        } else if (_state == CAP_STOPPING) {
            if (_cb.completeFlag || _cb.errFlag || ((now - _stateMs) >= STOP_TIMEOUT_MS)) {
                var drainedFinal = 0;
                while (drainedFinal < 16) {
                    var c = _cb.pop();
                    if (c == null) {
                        break;
                    }
                    drainedFinal++;
                    if (c.size() > 0) {
                        var isF = !_segHasFirstChunk;
                        _segHasFirstChunk = true;
                        ring.appendChunk(c, _rateKhz, _segId, _segEpoch, _tzOffsetMin, now - _segStartMs, isF);
                    }
                }
                var relEnd = now - _segStartMs;
                var isPartial = _wantStopAll || _stalled || (relEnd < (VoiceProto.SEG_DURATION_MS - 5000));
                ring.flushSegmentTail(_rateKhz, _segId, _segEpoch, _tzOffsetMin, relEnd, isPartial);
                _segsCompleted++;
                segJustSealed = true;

                if (_wantStopAll) {
                    _state = CAP_IDLE;
                } else {
                    _state = CAP_SETTLING;
                    _stateMs = now;
                }
            }
        } else if (_state == CAP_SETTLING) {
            if ((now - _stateMs) >= SETTLE_MS) {
                if (_wantStopAll) {
                    _state = CAP_IDLE;
                } else {
                    _segId++;
                    beginSegment();
                }
            }
        } else if (_state == CAP_INTERRUPTED) {
            if (_wantStopAll) {
                _state = CAP_IDLE;
                _interrupted = false;
            } else if ((now - _stateMs) >= INTERRUPT_RETRY_MS) {
                _stateMs = now;
                _segId++;
                if (beginSegment()) {
                    _interrupted = false;
                } else {
                    // Still backgrounded or blocked; keep interrupted until foreground returns or owner stops
                    _state = CAP_INTERRUPTED;
                    _interrupted = true;
                    _stopEndReason = VoiceProto.END_NONE;
                }
            }
        }

        return segJustSealed;
    }

    // Deterministic unit-test entry points (stripped from release builds via (:debug))
    (:debug)
    public function testEnterRunning(segId as Number, tzOffsetMin as Number) as Void {
        _segId = segId;
        _segEpoch = Time.now().value();
        _tzOffsetMin = tzOffsetMin;
        _segStartMs = System.getTimer();
        _lastChunkMs = _segStartMs;
        _segHasFirstChunk = false;
        _stalled = false;
        _interrupted = false;
        _wantStopAll = false;
        _stopEndReason = VoiceProto.END_NONE;
        _state = CAP_RUNNING;
        _cb.resetFlags();
    }

    (:debug)
    public function testCallbacks() as VoiceCaptureCallbacks {
        return _cb;
    }
}
