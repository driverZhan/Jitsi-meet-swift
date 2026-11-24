import Foundation
import QuartzCore
import os

/// RMS level of the PCM the custom audio device is moving, on the same 0...1 scale
/// `lib-jitsi-meet` uses for `TRACK_AUDIO_LEVEL_CHANGED`.
///
/// The lib derives the local microphone level with a WebAudio analyser. In WKWebView that
/// `AudioContext` is created suspended, so the conference never emits a level for the local
/// track and a level meter driven by those events stays flat. Sampling the device's own
/// buffers gives the meter a source even when the JS side stays silent.
public final class AudioLevelMonitor {
    public static let shared = AudioLevelMonitor()

    public enum Stream: Sendable {
        case microphone
        /// Remote mix, i.e. everyone else after the audio device mixed them down.
        case playout
    }

    private var lock = os_unfair_lock_s()
    private var microphone: Double = 0
    private var microphoneAt: CFTimeInterval = 0
    private var playout: Double = 0
    private var playoutAt: CFTimeInterval = 0

    private init() {}

    /// Latest microphone level; 0 once the stream has been quiet for 350 ms, so the meter
    /// falls back to empty instead of freezing on the last value.
    public var microphoneLevel: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return CACurrentMediaTime() - microphoneAt > 0.35 ? 0 : microphone
    }

    public var playoutLevel: Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return CACurrentMediaTime() - playoutAt > 0.35 ? 0 : playout
    }

    /// Called from the audio render thread: never blocks and never allocates. A contended
    /// lock just drops this buffer, which the next one covers.
    func ingest(_ samples: UnsafePointer<Int16>, frameCount: Int, stream: Stream) {
        guard frameCount > 0, os_unfair_lock_trylock(&lock) else { return }
        defer { os_unfair_lock_unlock(&lock) }

        // 256 taps are plenty for a meter and keep the render callback trivial.
        let stride = Swift.max(1, frameCount / 256)
        var sum = 0.0
        var measured = 0
        var index = 0
        while index < frameCount {
            let value = Double(samples[index]) / 32_768
            sum += value * value
            measured += 1
            index += stride
        }
        guard measured > 0 else { return }
        let rms = (sum / Double(measured)).squareRoot()
        let now = CACurrentMediaTime()
        switch stream {
        case .microphone:
            microphone = rms
            microphoneAt = now
        case .playout:
            playout = rms
            playoutAt = now
        }
    }
}
