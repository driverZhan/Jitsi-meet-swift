import AVFoundation
import CoreGraphics
import Foundation
import JitsiCore
import JitsiMedia
import Photos
import SwiftUI

/// Drives a `LocalVideoRecorder` from the demo's custom board layout and saves the finished
/// MP4 to the photo library. The recorder itself is layout-agnostic; this is the demo's
/// glue: it mirrors the same geometry `DemoMeetingScreen.board` uses, so the recording
/// matches what the user sees.
@MainActor
public final class LocalRecordingController: ObservableObject {
    @Published public private(set) var isRecording = false
    @Published public private(set) var status = ""

    /// Thread-safe box the recorder's `@Sendable` layout closure reads. Updated on the main
    /// actor whenever the visible canvases change; read on the recorder pump (also main actor).
    private struct LayoutState: Sendable {
        var localTrackID: TrackID?
        var remoteTrackIDs: [TrackID] = []
    }

    private final class LayoutBox: @unchecked Sendable {
        private let lock = NSLock()
        private var state = LayoutState()
        func set(localTrackID: TrackID?, remoteTrackIDs: [TrackID]) {
            lock.lock()
            state = LayoutState(localTrackID: localTrackID, remoteTrackIDs: remoteTrackIDs)
            lock.unlock()
        }
        func snapshot() -> LayoutState {
            lock.lock()
            defer { lock.unlock() }
            return state
        }
    }

    private let layoutBox = LayoutBox()
    private var recorder: LocalVideoRecorder?
    private let outputURL: URL

    public init(outputURL: URL? = nil) {
        if let outputURL {
            self.outputURL = outputURL
        } else {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.outputURL = dir.appendingPathComponent("jitsi-local-recording.mp4")
        }
    }

    /// Mirrors `DemoMeetingScreen.board`: local canvas is the stage, remote canvases form a
    /// 3-column grid below it. `canvasSize` is the recording canvas; the same ratios produce
    /// the same on-screen arrangement.
    /// - Parameters:
    ///   - localTrackID: track of the local self-view, nil when camera is off.
    ///   - remoteTrackIDs: remote video tracks in display order.
    nonisolated static func layout(
        localTrackID: TrackID?,
        remoteTrackIDs: [TrackID],
        canvasSize: CGSize
    ) -> [RecordingTile] {
        let width = canvasSize.width
        let height = canvasSize.height
        let stageHeight = height * 0.48
        let stageWidth = min(width - 16, stageHeight * 16 / 9)
        let remoteWidth = (width - 24) / 3
        let remoteHeight = remoteWidth * 9 / 16

        func normalized(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
            CGRect(
                x: x / width,
                y: y / height,
                width: w / width,
                height: h / height
            )
        }

        var tiles: [RecordingTile] = []
        if let localTrackID {
            tiles.append(RecordingTile(
                trackID: localTrackID,
                frame: normalized(
                    x: width / 2 - stageWidth / 2,
                    y: 8,
                    w: stageWidth,
                    h: stageHeight
                ),
                // The self-view is the stage; keep it above the floating remotes.
                zOrder: 1,
                contentMode: .fill
            ))
        }
        for (index, trackID) in remoteTrackIDs.enumerated() {
            let column = index % 3
            let row = index / 3
            tiles.append(RecordingTile(
                trackID: trackID,
                frame: normalized(
                    x: 8 + CGFloat(column) * (remoteWidth + 4),
                    y: 16 + stageHeight + CGFloat(row) * (remoteHeight + 4),
                    w: remoteWidth,
                    h: remoteHeight
                ),
                zOrder: 0,
                contentMode: .fill
            ))
        }
        return tiles
    }

    /// Called from the screen whenever the visible canvas set changes.
    func updateLayout(localTrackID: TrackID?, remoteTrackIDs: [TrackID]) {
        layoutBox.set(localTrackID: localTrackID, remoteTrackIDs: remoteTrackIDs)
    }

    func toggle() async {
        if isRecording {
            await stopAndSave()
        } else {
            await start()
        }
    }

    private func start() async {
        guard recorder == nil else { return }
        let canvas = CGSize(width: 1280, height: 720)
        let config = LocalRecordingConfiguration(
            outputURL: outputURL,
            canvasSize: canvas,
            frameRate: 24,
            videoBitrate: 2_000_000,
            codec: .h264
        )
        let box = layoutBox
        let newRecorder = LocalVideoRecorder(configuration: config) {
            let state = box.snapshot()
            return Self.layout(
                localTrackID: state.localTrackID,
                remoteTrackIDs: state.remoteTrackIDs,
                canvasSize: canvas
            )
        }
        do {
            try await newRecorder.start()
            recorder = newRecorder
            isRecording = true
            status = "Recording locally…"
        } catch {
            status = "Record failed: \(error.localizedDescription)"
        }
    }

    private func stopAndSave() async {
        guard let active = recorder else { return }
        do {
            _ = try await active.stop()
            recorder = nil
            isRecording = false
            status = "Saving to Photos…"
            try await saveToPhotoLibrary()
            status = "Saved to Photos"
        } catch {
            recorder = nil
            isRecording = false
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    private func saveToPhotoLibrary() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if current == .notDetermined {
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw PhotoSaveError.denied
            }
        } else if current != .authorized && current != .limited {
            throw PhotoSaveError.denied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: self.outputURL)
        }
    }
}

public enum PhotoSaveError: Error, LocalizedError {
    case denied
    public var errorDescription: String? {
        switch self {
        case .denied: return "Photo library access denied. Enable it in Settings."
        }
    }
}
