import WebRTC
import XCTest

/// Guards the one native assumption the JS bridge cannot check: the Jitsi WebRTC build
/// implements `RTCRtpSender.track` as a setter, which is how `sender.replaceTrack()` and
/// therefore every post-join `conference.addTrack()` reaches the encoder.
final class WebRTCSenderTests: XCTestCase {
    func testSenderTrackReplacement() throws {
        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let connection = factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        )
        let peer = try XCTUnwrap(connection, "the simulator has no usable WebRTC peer connection")

        let microphone = factory.audioTrack(withTrackId: "mic-1")
        let replacement = factory.audioTrack(withTrackId: "mic-2")
        let sender = try XCTUnwrap(peer.add(microphone, streamIds: ["stream-1"]))
        XCTAssertEqual(sender.track?.trackId, "mic-1")

        sender.track = replacement
        XCTAssertEqual(sender.track?.trackId, "mic-2")
        XCTAssertEqual(peer.transceivers.filter { $0.sender.senderId == sender.senderId }.count, 1)
    }
}
