import CoreGraphics
import Foundation
import JitsiCore
import JitsiMedia

/// Local recording for the Objective-C façade.
///
/// The layout mirrors the demo board: the local self-view is the stage and remote tracks sit
/// in a 3-column grid below it. Without a local track the remotes take the whole canvas.
/// `tiles` is evaluated on every recorded frame, so participants joining/leaving mid-recording
/// show up without restarting the file.
@MainActor
final class JitsiLocalRecording {
    private let outputURL: URL
    private let canvas: CGSize
    private let tiles: @MainActor () -> [RecordingTile]
    private var recorder: LocalVideoRecorder?

    init(
        outputURL: URL,
        canvas: CGSize = CGSize(width: 1280, height: 720),
        tiles: @escaping @MainActor () -> [RecordingTile]
    ) {
        self.outputURL = outputURL
        self.canvas = canvas
        self.tiles = tiles
    }

    var isRecording: Bool { recorder != nil }

    func start(audio: Bool) async throws {
        guard recorder == nil else { throw LocalRecordingError.alreadyRecording }
        let configuration = LocalRecordingConfiguration(
            outputURL: outputURL,
            canvasSize: canvas,
            frameRate: 24,
            videoBitrate: 2_000_000,
            codec: .h264,
            audio: audio ? AudioRecordingOptions() : nil
        )
        // `LocalVideoRecorder` calls the provider on the main actor; bridging the isolation
        // here keeps `tiles` simple and lets it read live conference state.
        let provider: @Sendable () -> [RecordingTile] = { [tiles] in
            MainActor.assumeIsolated { tiles() }
        }
        let recorder = LocalVideoRecorder(configuration: configuration, layoutProvider: provider)
        try await recorder.start()
        self.recorder = recorder
    }

    func stop() async throws -> URL {
        guard let recorder else { throw LocalRecordingError.notRecording }
        self.recorder = nil
        return try await recorder.stop()
    }

    func cancel() {
        recorder?.cancel()
        recorder = nil
    }

    static func layout(
        localTrackID: TrackID?,
        remoteTrackIDs: [TrackID],
        canvas: CGSize
    ) -> [RecordingTile] {
        let width = canvas.width
        let height = canvas.height
        guard width > 0, height > 0 else { return [] }

        func normalized(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> CGRect {
            CGRect(x: x / width, y: y / height, width: w / width, height: h / height)
        }

        var tiles: [RecordingTile] = []
        if let localTrackID {
            let stageHeight = height * 0.48
            let stageWidth = min(width - 16, stageHeight * 16 / 9)
            tiles.append(RecordingTile(
                trackID: localTrackID,
                frame: normalized(x: width / 2 - stageWidth / 2, y: 8, w: stageWidth, h: stageHeight),
                zOrder: 1,
                contentMode: .fill
            ))

            let remoteWidth = (width - 24) / 3
            let remoteHeight = remoteWidth * 9 / 16
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

        // Camera off: remotes fill the canvas.
        let count = remoteTrackIDs.count
        let columns = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        let rows = max(1, Int(ceil(Double(count) / Double(columns))))
        let cellWidth = (width - 8 * CGFloat(columns + 1)) / CGFloat(columns)
        let cellHeight = (height - 8 * CGFloat(rows + 1)) / CGFloat(rows)
        for (index, trackID) in remoteTrackIDs.enumerated() {
            let column = index % columns
            let row = index / columns
            tiles.append(RecordingTile(
                trackID: trackID,
                frame: normalized(
                    x: 8 + CGFloat(column) * (cellWidth + 8),
                    y: 8 + CGFloat(row) * (cellHeight + 8),
                    w: cellWidth,
                    h: cellHeight
                ),
                zOrder: 0,
                contentMode: .fill
            ))
        }
        return tiles
    }
}
