import Foundation

/// Fans one engine event stream out to any number of subscribers (API façades, the UI
/// store, diagnostics) without forcing them all onto a single `AsyncStream` consumer.
public final class EventHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: (MeetingEvent) -> Void] = [:]

    public init() {}

    public func subscribe(_ handler: @escaping (MeetingEvent) -> Void) -> Subscription {
        let id = UUID()
        lock.lock()
        subscribers[id] = handler
        lock.unlock()
        return Subscription { [weak self] in
            self?.lock.lock()
            self?.subscribers[id] = nil
            self?.lock.unlock()
        }
    }

    public func publish(_ event: MeetingEvent) {
        lock.lock()
        let handlers = Array(subscribers.values)
        lock.unlock()
        for handler in handlers {
            handler(event)
        }
    }
}

public struct Subscription: Hashable {
    private let cancel: @Sendable () -> Void

    init(_ cancel: @escaping @Sendable () -> Void) {
        self.cancel = cancel
    }

    public func unsubscribe() {
        cancel()
    }

    public static func == (_: Subscription, _: Subscription) -> Bool { true }
    public func hash(into hasher: inout Hasher) { hasher.combine(0) }
}
