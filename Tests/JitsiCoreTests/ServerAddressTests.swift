import XCTest
@testable import JitsiCore

final class ServerAddressTests: XCTestCase {
    func testBareHostDefaultsToSecureEndpoints() {
        let server = ServerAddress("meet.example.org")

        XCTAssertEqual(server.domain, "meet.example.org")
        XCTAssertEqual(server.host, "meet.example.org")
        XCTAssertEqual(server.origin, "https://meet.example.org")
        XCTAssertEqual(server.serviceUrl, "wss://meet.example.org/xmpp-websocket")
        XCTAssertEqual(server.muc, "conference.meet.example.org")
    }

    func testFullURLKeepsPortAndDropsSchemeFromTheDomain() {
        let server = ServerAddress("https://tmeeting.maesgroup.com:8443")

        XCTAssertEqual(server.domain, "tmeeting.maesgroup.com")
        XCTAssertEqual(server.host, "tmeeting.maesgroup.com:8443")
        XCTAssertEqual(server.origin, "https://tmeeting.maesgroup.com:8443")
        XCTAssertEqual(server.serviceUrl, "wss://tmeeting.maesgroup.com:8443/xmpp-websocket")
        XCTAssertEqual(server.muc, "conference.tmeeting.maesgroup.com")
    }

    func testPlainHTTPDowngradesTheSocketAndDropsThePath() {
        let server = ServerAddress("  http://meet.example.org:5280/jitsi/  ")

        XCTAssertEqual(server.origin, "http://meet.example.org:5280")
        XCTAssertEqual(server.serviceUrl, "ws://meet.example.org:5280/jitsi/xmpp-websocket")
    }

    func testBOSHUsesTheSameOriginAndKeepsExplicitDomains() {
        let server = ServerAddress(
            "https://tmeeting.maesgroup.com:8443",
            transport: .bosh,
            domain: "meet.jitsi",
            muc: "muc.meet.jitsi"
        )

        XCTAssertEqual(server.host, "tmeeting.maesgroup.com:8443")
        XCTAssertEqual(server.origin, "https://tmeeting.maesgroup.com:8443")
        XCTAssertEqual(server.serviceUrl, "https://tmeeting.maesgroup.com:8443/http-bind")
        XCTAssertEqual(server.domain, "meet.jitsi")
        XCTAssertEqual(server.muc, "muc.meet.jitsi")
    }

    func testEndpointPathIsNotDuplicated() {
        let bosh = ServerAddress("https://meet.example.org/jitsi/http-bind", transport: .bosh)
        let socket = ServerAddress("https://meet.example.org/jitsi/xmpp-websocket")

        XCTAssertEqual(bosh.serviceUrl, "https://meet.example.org/jitsi/http-bind")
        XCTAssertEqual(socket.serviceUrl, "wss://meet.example.org/jitsi/xmpp-websocket")
    }
}
