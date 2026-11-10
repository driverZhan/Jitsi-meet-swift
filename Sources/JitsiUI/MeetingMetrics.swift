import Combine
import Darwin
import Foundation

/// Coarse resource metrics for a running meeting.
///
/// Multi-party calls are the expensive case on iOS, so the numbers that matter are the
/// process-wide CPU load, the resident set, the thermal state and how long the first remote
/// video frame took to arrive. Sampling is opt-in: `start()` on join, `stop()` on leave.
@MainActor
public final class MeetingMetrics: ObservableObject {
    /// Fraction of one CPU core, so a busy decoder thread can push this above 100.
    @Published public private(set) var cpuPercent: Double = 0
    @Published public private(set) var residentBytes: UInt64 = 0
    @Published public private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    /// Seconds between `markJoined()` and the first remote video frame, or nil before it arrives.
    @Published public private(set) var firstRemoteFrameLatency: TimeInterval?

    private var timer: Timer?
    private var joinedAt: Date?
    private var firstRemoteFrameAt: Date?
    private var lastCPUTime: TimeInterval?
    private var lastSampleAt: Date?

    public init() {}

    public func start(interval: TimeInterval = 2) {
        stop()
        lastCPUTime = Self.processCPUTime()
        lastSampleAt = Date()
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        lastCPUTime = nil
        lastSampleAt = nil
    }

    /// Starts the clock for the first-frame measurement.
    public func markJoined(at date: Date = Date()) {
        joinedAt = date
        firstRemoteFrameAt = nil
        firstRemoteFrameLatency = nil
    }

    /// Called by the frame pipeline for remote tiles; only the first frame is recorded.
    public func markRemoteVideoFrame(at date: Date = Date()) {
        guard let joinedAt, firstRemoteFrameAt == nil else { return }
        firstRemoteFrameAt = date
        firstRemoteFrameLatency = date.timeIntervalSince(joinedAt)
    }

    private func sample() {
        let now = Date()
        residentBytes = Self.residentBytes()
        thermalState = ProcessInfo.processInfo.thermalState
        if let current = Self.processCPUTime(), let previous = lastCPUTime, let last = lastSampleAt {
            let wall = now.timeIntervalSince(last)
            if wall > 0 {
                cpuPercent = max(0, (current - previous) / wall * 100)
            }
        }
        lastCPUTime = Self.processCPUTime()
        lastSampleAt = now
    }

    private static func processCPUTime() -> TimeInterval? {
        var info = task_thread_times_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000
            + TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1_000_000
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}
