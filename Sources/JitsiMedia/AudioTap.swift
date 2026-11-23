import Foundation

/// Interleaved 16-bit PCM pulled out of the audio device on the realtime thread.
///
/// `didCapturePCM` is the microphone, `didPlayoutPCM` is the already-mixed remote audio.
/// Implementations must not allocate, lock, or hop queues here.
protocol AudioPCMTap: AnyObject {
    func didCapturePCM(_ samples: UnsafePointer<Int16>, frameCount: Int, hostTime: UInt64)
    func didPlayoutPCM(_ samples: UnsafePointer<Int16>, frameCount: Int, hostTime: UInt64)
}

/// Where a recorder installs its tap. Only the injected `RTCAudioDevice` implements this in
/// production; tests use a fake so the recorder can be exercised without an audio unit.
protocol AudioTapSource: AnyObject {
    var pcmTap: AudioPCMTap? { get set }
}

/// Process-wide handle to the injected audio device.
///
/// `LocalVideoRecorder` lives in this module but only sees the engine's public
/// `MediaBackend`, which must not grow a WebRTC-owned type, so the backend publishes the
/// device here. Weak: the backend keeps it alive for the call's lifetime.
enum AudioTapRegistry {
    static weak var source: (any AudioTapSource)?
}
