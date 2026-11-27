// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 sol pbc

import Toybox.Audio;
import Toybox.Audio.Capture;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;

// Tiny 3-method ISR-minimal Capture.Callbacks object — ZERO back-reference to app/runner,
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
        CAP_QUIET_WAIT
    }

    private const STALL_TIMEOUT_MS as Number = 45000; // >20s so flash GC pauses never false-alarm stall state
    private const SETTLE_MS as Number = 300;
    private const STOP_TIMEOUT_MS as Number = 3000;

    private var _cb as VoiceCaptureCallbacks;
    private var _state as CapState = CAP_IDLE;
    private var _initialized as Boolean = false;
    private var _rateKhz as Number = 16;

    private var _segId as Number = 0;
    private var _segEpoch as Number = 0;
    private var _segStartMs as Number = 0;
    private var _segHasFirstChunk as Boolean = false;
    private var _lastChunkMs as Number = 0;
    private var _stateMs as Number = 0;
    private var _stalled as Boolean = false;
    private var _segRecoveryDone as Boolean = false;
    private var _segsCompleted as Number = 0;
    private var _wantStopAll as Boolean = false;

    public function initialize() {
        _cb = new VoiceCaptureCallbacks();
    }

    public function getState() as CapState { return _state; }
    public function isRecording() as Boolean { return _state != CAP_IDLE; }
    public function isStalled() as Boolean { return _stalled; }
    public function segId() as Number { return _segId; }
    public function segEpoch() as Number { return _segEpoch; }
    public function segsCompleted() as Number { return _segsCompleted; }
    public function droppedChunks() as Number { return _cb.dropped; }
    public function lastError() as Number { return _cb.lastErr; }
    public function rateKhz() as Number { return _rateKhz; }

    public function startSession(startSegId as Number) as Boolean {
        _segId = startSegId;
        _wantStopAll = false;
        _stalled = false;
        return beginSegment();
    }

    public function stopSession() as Void {
        _wantStopAll = true;
        if (_state == CAP_RUNNING) {
            requestStopCapture();
        } else if (_state != CAP_STOPPING) {
            _state = CAP_IDLE;
        }
    }

    public function forceStopImmediate() as Void {
        _wantStopAll = true;
        try {
            if (Capture.getState() == Capture.CAPTURE_CAPTURING) {
                Capture.stop();
            }
        } catch (_) {}
        _state = CAP_IDLE;
    }

    // Resume next segment after Mode C quiet-window drain completes
    public function resumeAfterQuietDrain() as Void {
        if (_state == CAP_QUIET_WAIT && !_wantStopAll) {
            _segId++;
            beginSegment();
        }
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
            return false;
        }
    }

    private function beginSegment() as Boolean {
        if (!ensureInitialized()) {
            _stalled = true;
            _state = CAP_IDLE;
            return false;
        }
        _cb.resetFlags();
        _segHasFirstChunk = false;
        _segRecoveryDone = false;
        _segEpoch = Time.now().value();
        _segStartMs = System.getTimer();
        _lastChunkMs = _segStartMs;
        _stalled = false;
        try {
            Capture.start();
            _state = CAP_RUNNING;
            _stateMs = _segStartMs;
            VoiceProto.vlog("SV seg start id=" + _segId);
            return true;
        } catch (ex) {
            VoiceProto.vlog("SV Capture.start err=" + ex.getErrorMessage());
            _initialized = false; // Force clean re-init only on start failure
            _stalled = true;
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

    // Master 250ms tick: drains ISR ring into Storage, enforces 5m segment rotation and 45s stall watchdog.
    // Returns true when a 5m segment just sealed cleanly.
    public function tick(ring as VoiceStorageRing, modeId as Number) as Boolean {
        var now = System.getTimer();
        var segJustSealed = false;

        // 1. Drain any buffered chunks from ISR-minimal ring into Storage (bounded to <=8 chunks/tick for watchdog safety)
        var drained = 0;
        while (drained < 8) {
            var chunk = _cb.pop();
            if (chunk == null) {
                break;
            }
            drained++;
            // CIQQA-4919 guard: empty 0-byte chunks MUST NOT reset the stall watchdog
            if (chunk.size() == 0) {
                continue;
            }
            _lastChunkMs = now;
            _stalled = false;
            var isFirst = !_segHasFirstChunk;
            _segHasFirstChunk = true;
            var relMs = now - _segStartMs;
            if (!ring.appendChunk(chunk, modeId, _rateKhz, _segId, _segEpoch, relMs, isFirst)) {
                // Storage full — stop capture cleanly without overwriting undelivered audio
                stopSession();
                break;
            }
        }

        // 2. State machine transitions (NEVER called inside Capture.Callbacks)
        if (_state == CAP_RUNNING) {
            if (_cb.errFlag) {
                VoiceProto.vlog("SV cap err=" + _cb.lastErr);
                requestStopCapture();
                return false;
            }
            if ((now - _lastChunkMs) >= STALL_TIMEOUT_MS) {
                _stalled = true;
                // Attempt at most 1 clean stop->settle->start recovery per segment before latching MIC STALLED
                if (!_segRecoveryDone) {
                    _segRecoveryDone = true;
                    VoiceProto.vlog("SV stall recovery seg=" + _segId);
                    requestStopCapture();
                    return false;
                }
            }
            if ((now - _segStartMs) >= VoiceProto.SEG_DURATION_MS) {
                requestStopCapture();
            }
            return false;
        }

        if (_state == CAP_STOPPING) {
            var capDone = _cb.completeFlag || (Capture.getState() != Capture.CAPTURE_CAPTURING) || ((now - _stateMs) >= STOP_TIMEOUT_MS);
            if (capDone) {
                // Drain any final EOS audio chunks flushed by Capture.stop()
                while (true) {
                    var tail = _cb.pop();
                    if (tail == null) { break; }
                    var isFirst2 = !_segHasFirstChunk;
                    _segHasFirstChunk = true;
                    ring.appendChunk(tail, modeId, _rateKhz, _segId, _segEpoch, now - _segStartMs, isFirst2);
                }
                ring.flushSegmentTail(modeId, _rateKhz, _segId, _segEpoch, now - _segStartMs);
                _segsCompleted++;
                segJustSealed = true;

                if (_wantStopAll || ring.isFull()) {
                    _state = CAP_IDLE;
                } else if (modeId == VoiceProto.MODE_QUIET_BURST) {
                    _state = CAP_QUIET_WAIT;
                    _stateMs = now;
                } else {
                    _state = CAP_SETTLING;
                    _stateMs = now;
                }
            }
            return segJustSealed;
        }

        if (_state == CAP_SETTLING) {
            if ((now - _stateMs) >= SETTLE_MS) {
                if (_wantStopAll || ring.isFull()) {
                    _state = CAP_IDLE;
                } else {
                    _segId++;
                    beginSegment();
                }
            }
            return false;
        }

        return false;
    }
}
