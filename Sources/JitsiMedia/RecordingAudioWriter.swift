import Darwin
import AVFoundation
import CoreMedia
import Foundation
import JitsiCore
import os

/// Converts the audio unit's host clock into a sample index relative to the recording start.
/// Both the video pump and the audio mixer use this clock, which is what keeps lip sync.
struct AudioSampleClock {
    let startHostTime: UInt64
    let sampleRate: Int

    init(startHostTime: UInt64, sampleRate: Int = 48_000) {
        self.startHostTime = startHostTime
        self.sampleRate = sampleRate
    }

    /// Sample index at `hostTime`. Buffers already in flight when recording starts map to
    /// zero instead of a negative index.
    func sampleIndex(forHostTime hostTime: UInt64) -> Int64 {
        let start = HostClock.nanos(startHostTime)
        let now = HostClock.nanos(hostTime)
        guard now > start else { return 0 }
        let nanos = Double(now - start)
        return Int64((nanos * Double(sampleRate) / 1_000_000_000).rounded())
    }
}

/// Mixes the microphone tap and the remote-playout tap into one mono stream.
///
/// The two taps run on the same audio unit, so their timestamps share a clock but their
/// callbacks are independent. Samples are therefore indexed by timestamp, not by arrival
/// order: a sample from the missing stream is treated as silence once the other stream is
/// more than `silenceGap` ahead, which keeps a mic-only or playout-only recording running
/// instead of stalling.
///
/// One lock covers `ingest` (audio thread) and `takeSamples` (writer queue); both critical
/// sections are bounded and allocation-free on the ingest side.
final class RecordingAudioMixer {
    enum Stream { case microphone, playout }

    static let defaultSampleRate = 48_000
    /// 5 s of headroom in each ring; the writer drains every 50 ms.
    private static let capacitySeconds = 5
    /// How far ahead one stream may run before the other is treated as silent.
    private static let silenceGapSeconds = 0.5

    let sampleRate: Int
    private let capacity: Int
    private let silenceGap: Int64
    private let lock = NSLock()

    private var micRing: [Int16]
    private var playoutRing: [Int16]
    private var outputRing: [Int16]

    /// Absolute index of the next sample to mix out.
    private var flushed: Int64 = 0
    private var micEnd: Int64 = 0
    private var playoutEnd: Int64 = 0
    private var outputStart: Int64 = 0
    private var outputEnd: Int64 = 0
    private var hasOutput = false
    private(set) var droppedSamples: Int64 = 0
    private var finished = false

    init(sampleRate: Int = RecordingAudioMixer.defaultSampleRate) {
        self.sampleRate = sampleRate
        capacity = sampleRate * Self.capacitySeconds
        silenceGap = Int64(Double(sampleRate) * Self.silenceGapSeconds)
        micRing = [Int16](repeating: 0, count: capacity)
        playoutRing = [Int16](repeating: 0, count: capacity)
        outputRing = [Int16](repeating: 0, count: capacity)
    }

    /// Audio thread. `startIndex` is the absolute sample position of `samples[0]`.
    func ingest(stream: Stream, samples: UnsafeBufferPointer<Int16>, startIndex: Int64) {
        guard samples.count > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }

        let end = stream == .microphone ? micEnd : playoutEnd
        // Late packets (older than what we already mixed) are dropped: rewriting them would
        // create a discontinuity in the middle of the output.
        guard startIndex + Int64(samples.count) > flushed else {
            droppedSamples += Int64(samples.count)
            return
        }
        // A jump forward leaves a hole; zero it so stale ring content is never mixed in.
        if startIndex > end {
            zero(stream: stream, from: end, to: startIndex)
        }
        let clippedStart = max(startIndex, flushed)
        let skip = Int(clippedStart - startIndex)
        let count = samples.count - skip
        guard count > 0, clippedStart + Int64(count) <= flushed + Int64(capacity) else {
            droppedSamples += Int64(samples.count)
            return
        }

        var ring = stream == .microphone ? micRing : playoutRing
        let startSlot = Int(clippedStart % Int64(capacity))
        let firstRun = min(count, capacity - startSlot)
        for i in 0..<firstRun {
            ring[startSlot + i] = samples[skip + i]
        }
        if firstRun < count {
            for i in 0..<(count - firstRun) {
                ring[i] = samples[skip + firstRun + i]
            }
        }
        if stream == .microphone {
            micRing = ring
            micEnd = max(micEnd, clippedStart + Int64(count))
        } else {
            playoutRing = ring
            playoutEnd = max(playoutEnd, clippedStart + Int64(count))
        }
        flushLocked(limit: availableLimit())
    }

    /// Writer queue. Returns the next contiguous chunk together with its absolute start index.
    func takeSamples(maxCount: Int) -> (samples: [Int16], startIndex: Int64)? {
        lock.lock()
        defer { lock.unlock() }
        guard hasOutput, outputStart < outputEnd else { return nil }
        let count = min(maxCount, Int(outputEnd - outputStart))
        guard count > 0 else { return nil }
        var chunk = [Int16](repeating: 0, count: count)
        let start = outputStart
        let slot = Int(start % Int64(capacity))
        let firstRun = min(count, capacity - slot)
        for i in 0..<firstRun {
            chunk[i] = outputRing[slot + i]
        }
        if firstRun < count {
            for i in 0..<(count - firstRun) {
                chunk[firstRun + i] = outputRing[i]
            }
        }
        outputStart = start + Int64(count)
        return (chunk, start)
    }

    /// Flushes everything the taps delivered, treating the missing side as silence.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        flushLocked(limit: max(micEnd, playoutEnd))
        finished = true
    }

    // MARK: - Internals

    /// How far we can mix without guessing: both streams covered, or one of them silent for
    /// longer than `silenceGap`.
    private func availableLimit() -> Int64 {
        let low = min(micEnd, playoutEnd)
        let high = max(micEnd, playoutEnd)
        return max(low, high - silenceGap)
    }

    private func flushLocked(limit: Int64) {
        guard limit > flushed else { return }
        while flushed < limit {
            let mic = flushed < micEnd ? micRing[Int(flushed % Int64(capacity))] : 0
            let playout = flushed < playoutEnd ? playoutRing[Int(flushed % Int64(capacity))] : 0
            let mixed = Self.saturatingSum(mic, playout)
            if !hasOutput {
                hasOutput = true
                outputStart = flushed
            }
            if outputEnd - outputStart < Int64(capacity) {
                outputRing[Int(outputEnd % Int64(capacity))] = mixed
                outputEnd += 1
            } else {
                droppedSamples += 1
            }
            flushed += 1
        }
    }

    private func zero(stream: Stream, from: Int64, to: Int64) {
        guard to > from else { return }
        var ring = stream == .microphone ? micRing : playoutRing
        var index = from
        while index < to {
            ring[Int(index % Int64(capacity))] = 0
            index += 1
        }
        if stream == .microphone {
            micRing = ring
        } else {
            playoutRing = ring
        }
    }

    /// Sum with clipping. Speech rarely clips; double-talk can, and wrapping would sound
    /// like a click.
    static func saturatingSum(_ a: Int16, _ b: Int16) -> Int16 {
        Int16(clamping: Int32(a) + Int32(b))
    }
}

/// Receives the audio device taps and writes one AAC track into an existing asset writer.
///
/// `AVAssetWriterInput.append` must not run on the audio thread, so the taps only fill the
/// mixer and a 50 ms timer on a private queue drains it.
final class RecordingAudioWriter: AudioPCMTap {
    private static let log = Logger(subsystem: "org.jitsi.sdk", category: "recording")
    private static let chunkSamples = 4_800 // 100 ms

    let input: AVAssetWriterInput
    private let mixer: RecordingAudioMixer
    private let clock: AudioSampleClock
    private let format: CMAudioFormatDescription
    private let queue = DispatchQueue(label: "org.jitsi.sdk.recording-audio")
    private var timer: DispatchSourceTimer?
    private var isFinished = false

    init(writer: AVAssetWriter, startHostTime: UInt64, sampleRate: Int = RecordingAudioMixer.defaultSampleRate) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw LocalRecordingError.writerFailed("cannot add audio input")
        }
        writer.add(input)

        mixer = RecordingAudioMixer(sampleRate: sampleRate)
        clock = AudioSampleClock(startHostTime: startHostTime, sampleRate: sampleRate)

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var audioFormat: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &description,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &audioFormat
        )
        guard status == noErr, let audioFormat else {
            throw LocalRecordingError.writerFailed("audio format description failed")
        }
        format = audioFormat
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Stops the tap, flushes the mixer and marks the track finished. The caller still owns
    /// `AVAssetWriter.finishWriting`.
    func finish() {
        timer?.cancel()
        timer = nil
        queue.sync {
            mixer.finish()
            drainLocked()
            input.markAsFinished()
            isFinished = true
        }
        if mixer.droppedSamples > 0 {
            Self.log.error("recording audio dropped \(self.mixer.droppedSamples) samples")
        }
    }

    func cancel() {
        timer?.cancel()
        timer = nil
        isFinished = true
    }

    // MARK: - AudioPCMTap

    func didCapturePCM(_ samples: UnsafePointer<Int16>, frameCount: Int, hostTime: UInt64) {
        let start = clock.sampleIndex(forHostTime: hostTime)
        mixer.ingest(
            stream: .microphone,
            samples: UnsafeBufferPointer(start: samples, count: frameCount),
            startIndex: start
        )
    }

    func didPlayoutPCM(_ samples: UnsafePointer<Int16>, frameCount: Int, hostTime: UInt64) {
        let start = clock.sampleIndex(forHostTime: hostTime)
        mixer.ingest(
            stream: .playout,
            samples: UnsafeBufferPointer(start: samples, count: frameCount),
            startIndex: start
        )
    }

    // MARK: - Writer

    private func drain() {
        queue.async { [weak self] in
            guard let self, !self.isFinished else { return }
            self.drainLocked()
        }
    }

    private func drainLocked() {
        while input.isReadyForMoreMediaData, let chunk = mixer.takeSamples(maxCount: Self.chunkSamples) {
            guard let buffer = Self.makeSampleBuffer(
                chunk.samples,
                startIndex: chunk.startIndex,
                format: format,
                sampleRate: mixer.sampleRate
            ) else {
                continue
            }
            if !input.append(buffer) {
                Self.log.error("recording audio append failed: \(String(describing: self.input), privacy: .public)")
                break
            }
        }
    }

    private static func makeSampleBuffer(
        _ samples: [Int16],
        startIndex: Int64,
        format: CMAudioFormatDescription,
        sampleRate: Int
    ) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else {
            return nil
        }
        guard CMBlockBufferAssureBlockMemory(blockBuffer) == kCMBlockBufferNoErr else { return nil }
        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: startIndex, timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else {
            return nil
        }
        return sampleBuffer
    }
}


