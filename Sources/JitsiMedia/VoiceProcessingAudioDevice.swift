#if canImport(WebRTC)
import AudioToolbox
import AVFoundation
import Foundation
import os
import WebRTC

/// Stage-0 probe for taking over libwebrtc's audio device module (see README §12.5).
///
/// The whole point is to own the PCM path: `RTCAudioDevice` hands us the microphone buffer
/// and asks us to fill the playout buffer, so the local recorder can mix those two streams
/// later without a second audio unit fighting the call for the microphone.
///
/// Deliberate limits of this stage:
/// * Fixed 48 kHz / mono / Int16. The `VoiceProcessingIO` unit resamples the underlying
///   route, so the contract stays stable across receiver, speaker and Bluetooth.
/// * Session configuration uses `.voiceChat`, so hardware echo cancellation is preserved —
///   the same audio unit the built-in ADM uses. Do not swap in plain `RemoteIO`.
/// * Interruption resume and route-parameter renegotiation are best-effort; the full policy
///   lands with the recording mixer. The flag that enables this device is off by default.
///
/// Contract notes from `RTCAudioDevice.h`: every member is called on the ADM thread between
/// `initializeWithDelegate:` and `terminateDevice`, the implementation is fully responsible
/// for `AVAudioSession`, and the notify methods must run inside `dispatchAsync`/`dispatchSync`.
final class VoiceProcessingAudioDevice: NSObject, RTCAudioDevice {
    static let sampleRate: Double = 48_000
    static let channelCount: Int = 1

    /// Largest buffer the audio unit may hand us in one callback. 48 kHz × 170 ms.
    private static let maximumFrames = 8_192
    private static let uint32Size = UInt32(MemoryLayout<UInt32>.size)
    private static let asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    private static let callbackSize = UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    private static let log = Logger(subsystem: "org.jitsi.sdk", category: "audio-device")

    // MARK: - State

    private let lock = NSLock()
    private var delegate: RTCAudioDeviceDelegate?
    private var unit: AudioUnit?
    private var sessionObservers: [NSObjectProtocol] = []
    private var sessionActive = false
    private var speakerPreferred = false
    private var initialized = false
    private var playoutInitialized = false
    private var recordingInitialized = false
    private var playing = false
    private var recording = false

    /// Preallocated so the render callback never touches the allocator.
    private var inputBuffer: AVAudioPCMBuffer?

    /// One-shot probes for `JITSI_ADM_TRACE=1`; written on the audio thread, only ever
    /// flipped false → true.
    private var didTraceMicDeliver = false
    private var didTracePlayoutPull = false

    /// Installed/removed while the unit is running (the recorder starts mid-call), so the
    /// audio thread reads it under a short lock instead of racing an ARC store.
    private var tapLock = NSLock()
    private var storedTap: AudioPCMTap?

    var pcmTap: AudioPCMTap? {
        get {
            tapLock.lock()
            defer { tapLock.unlock() }
            return storedTap
        }
        set {
            tapLock.lock()
            storedTap = newValue
            tapLock.unlock()
        }
    }

    deinit {
        removeSessionObservers()
        teardownUnit()
    }

    // MARK: - Session ownership (called by `WebRTCBackend`, not by libwebrtc)

    /// Configures and activates `AVAudioSession` before capture opens. The built-in ADM is
    /// bypassed when this device is injected, so nothing else will do it.
    func activate(preferSpeaker: Bool) throws {
        try configureSession(preferSpeaker: preferSpeaker)
        lock.lock()
        speakerPreferred = preferSpeaker
        sessionActive = true
        lock.unlock()
    }

    /// Mirrors `AudioSessionManager.preferSpeaker` for the injected-device path.
    func setSpeaker(_ speaker: Bool) throws {
        lock.lock()
        speakerPreferred = speaker
        let active = sessionActive
        lock.unlock()
        guard active else { return }
        try configureSession(preferSpeaker: speaker)
    }

    /// Releases the session on leave. Keeps the audio unit so a rejoin can restart it.
    func deactivate() {
        updateUnitState(running: false)
        lock.lock()
        sessionActive = false
        playing = false
        recording = false
        lock.unlock()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - RTCAudioDevice lifecycle

    var isInitialized: Bool { locked { initialized } }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        lock.lock()
        guard !initialized else {
            lock.unlock()
            return false
        }
        self.delegate = delegate
        lock.unlock()

        do {
            let unit = try makeUnit()
            lock.lock()
            self.unit = unit
            initialized = true
            lock.unlock()
            Self.trace("[adm] unit created (VoiceProcessingIO)")
            observeSession()
            Self.log.notice("custom audio device initialized rate=\(Self.sampleRate, privacy: .public)")
            Self.trace("[adm] initialized rate=48000 mono")
            return true
        } catch {
            Self.log.error("custom audio device init failed: \(String(describing: error), privacy: .public)")
            Self.trace("[adm] init FAILED")
            return false
        }
    }

    func terminateDevice() -> Bool {
        stopUnit()
        teardownUnit()
        removeSessionObservers()

        lock.lock()
        delegate = nil
        initialized = false
        playoutInitialized = false
        recordingInitialized = false
        playing = false
        recording = false
        sessionActive = false
        inputBuffer = nil
        pcmTap = nil
        lock.unlock()

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return true
    }

    // MARK: - Playout

    var isPlaying: Bool { locked { playing } }
    var isPlayoutInitialized: Bool { locked { playoutInitialized } }

    func initializePlayout() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard initialized else { return false }
        playoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        guard activateIfNeeded() else { return false }
        lock.lock()
        playing = true
        lock.unlock()
        updateUnitState(running: true)
        Self.trace("[adm] playout started")
        return true
    }

    func stopPlayout() -> Bool {
        lock.lock()
        playing = false
        let stillRecording = recording
        lock.unlock()
        if !stillRecording { updateUnitState(running: false) }
        return true
    }

    // MARK: - Recording

    var isRecording: Bool { locked { recording } }
    var isRecordingInitialized: Bool { locked { recordingInitialized } }

    func initializeRecording() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard initialized else { return false }
        if inputBuffer == nil {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.sampleRate,
                channels: AVAudioChannelCount(Self.channelCount),
                interleaved: true
            ), let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Self.maximumFrames)
            ) else {
                return false
            }
            inputBuffer = buffer
        }
        recordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        guard activateIfNeeded() else { return false }
        lock.lock()
        recording = true
        lock.unlock()
        updateUnitState(running: true)
        Self.trace("[adm] recording started")
        return true
    }

    func stopRecording() -> Bool {
        lock.lock()
        recording = false
        let stillPlaying = playing
        lock.unlock()
        if !stillPlaying { updateUnitState(running: false) }
        return true
    }

    // MARK: - Device parameters

    // The audio unit converts to the fixed stream format above, so these stay constant. The
    // ADM uses them to size its own buffers; report the session's real latency/duration.

    var deviceInputSampleRate: Double { Self.sampleRate }
    var deviceOutputSampleRate: Double { Self.sampleRate }
    var inputNumberOfChannels: Int { Self.channelCount }
    var outputNumberOfChannels: Int { Self.channelCount }
    var inputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    // MARK: - Session

    private func configureSession(preferSpeaker: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if preferSpeaker { options.insert(.defaultToSpeaker) }
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setPreferredSampleRate(Self.sampleRate)

        var duration = 0.01
        if let delegate {
            let preferred = max(delegate.preferredInputIOBufferDuration, delegate.preferredOutputIOBufferDuration)
            if preferred > 0 { duration = preferred }
        }
        try session.setPreferredIOBufferDuration(duration)
        try session.setActive(true)
    }

    private func activateIfNeeded() -> Bool {
        lock.lock()
        let active = sessionActive
        let speaker = speakerPreferred
        lock.unlock()
        guard !active else { return true }
        do {
            try configureSession(preferSpeaker: speaker)
            lock.lock()
            sessionActive = true
            lock.unlock()
            Self.trace(speaker ? "[adm] session active speaker" : "[adm] session active receiver")
            return true
        } catch {
            Self.log.error("AVAudioSession activation failed: \(String(describing: error), privacy: .public)")
            Self.trace("[adm] session activation FAILED")
            return false
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        let interrupted = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        }
        let rerouted = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.notifyParameterChange()
        }
        lock.lock()
        sessionObservers = [interrupted, rerouted]
        lock.unlock()
    }

    private func removeSessionObservers() {
        lock.lock()
        let observers = sessionObservers
        sessionObservers = []
        lock.unlock()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            Self.interrupt(delegate: delegate)
        case .ended:
            // The ADM only learns about interruption through these calls; after it ends the
            // device has to bring its own unit back if it was running.
            lock.lock()
            let running = playing || recording
            sessionActive = false
            lock.unlock()
            guard running, activateIfNeeded() else { return }
            updateUnitState(running: true)
            notifyParameterChange()
        @unknown default:
            break
        }
    }

    private static func interrupt(delegate: RTCAudioDeviceDelegate?) {
        guard let delegate else { return }
        delegate.dispatchAsync {
            delegate.notifyAudioInputInterrupted()
            delegate.notifyAudioOutputInterrupted()
        }
    }

    /// Route changes can move the IO buffer duration and the hardware latency, so tell the ADM
    /// to re-read the parameter properties. Both notify calls must run on the ADM thread.
    private func notifyParameterChange() {
        guard let delegate else { return }
        delegate.dispatchAsync {
            delegate.notifyAudioInputParametersChange()
            delegate.notifyAudioOutputParametersChange()
        }
    }

    // MARK: - Audio unit

    private func makeUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw AudioDeviceError.unitUnavailable
        }

        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let unit = instance else {
            throw AudioDeviceError.unitUnavailable
        }

        var enable: UInt32 = 1
        var status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            1,
            &enable,
            Self.uint32Size
        )

        // Microphone leaves the unit on element 1's output scope; playout enters on element 0's
        // input scope. Both are pinned to 48 kHz mono Int16 to match the ADM contract.
        var format = Self.streamFormat
        if status == noErr {
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output,
                1,
                &format,
                Self.asbdSize
            )
        }
        if status == noErr {
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input,
                0,
                &format,
                Self.asbdSize
            )
        }

        var inputCallback = AURenderCallbackStruct(
            inputProc: Self.inputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                1,
                &inputCallback,
                Self.callbackSize
            )
        }

        var outputCallback = AURenderCallbackStruct(
            inputProc: Self.outputProc,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        if status == noErr {
            status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &outputCallback,
                Self.callbackSize
            )
        }

        guard status == noErr, AudioUnitInitialize(unit) == noErr else {
            AudioComponentInstanceDispose(unit)
            throw AudioDeviceError.unitUnavailable
        }
        return unit
    }

    private func teardownUnit() {
        lock.lock()
        let unit = self.unit
        self.unit = nil
        lock.unlock()
        guard let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func updateUnitState(running: Bool) {
        lock.lock()
        let unit = self.unit
        lock.unlock()
        guard let unit else { return }
        if running {
            AudioOutputUnitStart(unit)
        } else {
            AudioOutputUnitStop(unit)
        }
    }

    private func stopUnit() {
        lock.lock()
        let unit = self.unit
        lock.unlock()
        if let unit { AudioOutputUnitStop(unit) }
    }

    // MARK: - Render callbacks

    /// Runs on the audio thread. Everything it touches is set before `start*` and cleared
    /// after `stop*`, which is why it takes no lock.
    private func handleInput(
        _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ bus: UInt32,
        _ frameCount: UInt32
    ) -> OSStatus {
        guard let unit, let buffer = inputBuffer else { return noErr }
        guard Int(frameCount) <= Int(buffer.frameCapacity) else {
            return noErr
        }

        buffer.frameLength = frameCount
        let status = AudioUnitRender(
            unit,
            actionFlags,
            timestamp,
            bus,
            frameCount,
            buffer.mutableAudioBufferList
        )
        guard status == noErr else { return status }

        _ = delegate?.deliverRecordedData(
            actionFlags,
            timestamp,
            1,
            frameCount,
            UnsafePointer(buffer.audioBufferList),
            nil,
            nil
        )

        if let data = buffer.audioBufferList.pointee.mBuffers.mData {
            let pcm = data.assumingMemoryBound(to: Int16.self)
            AudioLevelMonitor.shared.ingest(pcm, frameCount: Int(frameCount), stream: .microphone)
            if let tap = pcmTap {
                tap.didCapturePCM(
                    pcm,
                    frameCount: Int(frameCount),
                    hostTime: timestamp.pointee.mHostTime
                )
            }
        }
        if !didTraceMicDeliver {
            didTraceMicDeliver = true
            Self.trace("[adm] first mic deliver")
        }
        return noErr
    }

    /// Runs on the audio thread. `getPlayoutData` filling `ioData` directly avoids a copy.
    private func handleOutput(
        _ actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timestamp: UnsafePointer<AudioTimeStamp>,
        _ frameCount: UInt32,
        _ ioData: UnsafeMutablePointer<AudioBufferList>?
    ) -> OSStatus {
        guard let ioData else { return noErr }
        guard let delegate else {
            Self.fillSilence(ioData)
            return noErr
        }

        let status = delegate.getPlayoutData(actionFlags, timestamp, 0, frameCount, ioData)
        guard status == noErr else {
            Self.fillSilence(ioData)
            return noErr
        }

        if let data = ioData.pointee.mBuffers.mData {
            let pcm = data.assumingMemoryBound(to: Int16.self)
            AudioLevelMonitor.shared.ingest(pcm, frameCount: Int(frameCount), stream: .playout)
            if let tap = pcmTap {
                tap.didPlayoutPCM(
                    pcm,
                    frameCount: Int(frameCount),
                    hostTime: timestamp.pointee.mHostTime
                )
            }
        }
        if !didTracePlayoutPull {
            didTracePlayoutPull = true
            Self.trace("[adm] first playout pull")
        }
        return noErr
    }

    private static let inputProc: AURenderCallback = {
        reference, actionFlags, timestamp, bus, frameCount, _ in
        Unmanaged<VoiceProcessingAudioDevice>.fromOpaque(reference)
            .takeUnretainedValue()
            .handleInput(actionFlags, timestamp, bus, frameCount)
    }

    private static let outputProc: AURenderCallback = {
        reference, actionFlags, timestamp, _, frameCount, ioData in
        Unmanaged<VoiceProcessingAudioDevice>.fromOpaque(reference)
            .takeUnretainedValue()
            .handleOutput(actionFlags, timestamp, frameCount, ioData)
    }

    private static func fillSilence(_ ioData: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(ioData) {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private static var streamFormat: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 16,
            mReserved: 0
        )
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// On-device verification hook. `Logger` only reaches the unified log, which needs root
    /// to collect from a device, and `idevicesyslog` cannot decode NSLog format arguments
    /// (they show up as `<private>` / `<decode: missing data>`). These are fixed strings so
    /// they survive both transports. Off unless `JITSI_ADM_TRACE=1` is in the launch
    /// environment, so production builds stay silent.
    private static let traceEnabled = ProcessInfo.processInfo.environment["JITSI_ADM_TRACE"] == "1"

    private static func trace(_ line: String) {
        guard traceEnabled else { return }
        NSLog(line)
    }
}

enum AudioDeviceError: LocalizedError {
    case unitUnavailable

    var errorDescription: String? {
        switch self {
        case .unitUnavailable:
            return "VoiceProcessingIO audio unit could not be created or configured"
        }
    }
}
extension VoiceProcessingAudioDevice: AudioTapSource {}
#endif
