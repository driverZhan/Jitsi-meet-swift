import CoreMedia
import LJMeet
import ReplayKit

/// Broadcast upload extension entry point.
///
/// Add this file to a Broadcast Upload Extension target in the host app (the target kind
/// Xcode creates for "Broadcast Upload Extension"), set the App Group on both targets and
/// replace the value below with that group. No other extension code is needed: the sender
/// lives in the SDK, so the extension links the same LJMeet binary as the app.
final class SampleHandler: RPBroadcastSampleHandler {
    private let appGroupIdentifier = "group.com.jitsi.meetsdk"
    private var sender: ScreenShareBroadcastSender?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        ScreenShareConfiguration.appGroupIdentifier = appGroupIdentifier
        sender = ScreenShareBroadcastSender(appGroupIdentifier: appGroupIdentifier)
        if sender == nil {
            finishBroadcastWithError(NSError(
                domain: "JitsiScreenShare",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group \(appGroupIdentifier) is not configured for the extension."]
            ))
        }
    }

    override func broadcastPaused() {}

    override func broadcastResumed() {}

    override func broadcastFinished() {
        sender?.close()
        sender = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let timestampUs = Int64(CMTimeGetSeconds(time) * 1_000_000)
        sender?.send(pixelBuffer: pixelBuffer, timestampUs: timestampUs, rotation: .none)
    }
}
