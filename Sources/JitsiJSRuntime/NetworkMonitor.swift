import Foundation
import Network

/// Feeds reachability changes into lib-jitsi-meet's `setNetworkInfo()`. Without them the
/// resume task retries blindly and gives up after three BOSH attempts even when the radio
/// is still coming back.
///
/// `@unchecked Sendable`: NWPathMonitor owns its delivery queue, and the stored handler is
/// only ever invoked from there.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.jitsi.network-monitor")
    private let handler: @Sendable (Bool) -> Void

    init(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func start() {
        monitor.pathUpdateHandler = { [handler] path in
            handler(path.status == .satisfied)
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
