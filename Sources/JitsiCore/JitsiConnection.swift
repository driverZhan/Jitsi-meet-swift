import Foundation

@MainActor
public final class JitsiConnection {
    public let options: ConnectionOptions

    /// Source of truth is the engine's `connectionStatus` event, not the return of
    /// `engine.connect`, because XMPP connect is asynchronous inside lib-jitsi-meet.
    public private(set) var status: ConnectionStatus = .idle {
        didSet {
            guard status != oldValue else { return }
            for listener in listeners.values {
                listener(status)
            }
            switch status {
            case .connected:
                settle(with: .success(()))
            case .error:
                settle(with: .failure(JitsiError.remote(lastError ?? "connection failed")))
            case .disconnected:
                settle(with: .failure(JitsiError.notConnected))
            case .connecting, .idle:
                break
            }
        }
    }

    public private(set) var lastError: String?

    /// XMPP deployment info published by the server during login (`PROPERTIES_UPDATED`).
    /// Values are `region` and `shard`; unknown keys are kept as-is.
    public private(set) var properties: [String: JSONValue] = [:]

    public var deploymentRegion: String? { properties["region"]?.stringValue }
    public var deploymentShard: String? { properties["shard"]?.stringValue }

    /// How long to wait for `CONNECTION_ESTABLISHED` after the connect call before failing.
    public var connectTimeout: TimeInterval = 20

    private var listeners: [UUID: (ConnectionStatus) -> Void] = [:]
    private var waiters: [UUID: (Result<Void, Error>) -> Void] = [:]
    private var hubSubscription: Subscription?

    init(options: ConnectionOptions) {
        self.options = options
        hubSubscription = JitsiMeet.shared.events.subscribe { [weak self] event in
            Task { @MainActor in
                switch event {
                case .connectionStatus(let next, let message):
                    self?.lastError = message
                    self?.status = next
                case .connectionPropertiesUpdated(let payload):
                    if case .object(let entries) = payload {
                        self?.properties = entries
                    }
                default:
                    break
                }
            }
        }
    }

    deinit {
        hubSubscription?.unsubscribe()
    }

    /// A fresh stream per call: `AsyncStream` has one consumer, and a shared property would
    /// silently steal events between callers.
    public func statusChanges() -> AsyncStream<ConnectionStatus> {
        let token = UUID()
        let current = status
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            continuation.yield(current)
            self.listeners[token] = { continuation.yield($0) }
            continuation.onTermination = { _ in
                Task { @MainActor in self.listeners[token] = nil }
            }
        }
    }

    public func connect() async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        properties = [:]
        status = .connecting
        try await engine.connect(options)
        try await waitUntilEstablished()
    }

    public func disconnect() async {
        await JitsiMeet.shared.engine?.disconnect()
        status = .disconnected
    }

    /// Supplies a new JWT after the server reports the current one expired. lib-jitsi-meet
    /// only asks for this while resuming a dropped stream, and cancels the resume if no
    /// token arrives.
    public func refreshToken(_ token: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        try await engine.refreshToken(token)
    }

    public func join(_ options: ConferenceOptions) async throws -> JitsiConference {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard status == .connected else { throw JitsiError.notConnected }
        try await engine.joinConference(options)
        return JitsiConference(options: options)
    }

    // MARK: - Waiting

    private func waitUntilEstablished() async throws {
        guard status != .connected else { return }
        let token = UUID()
        let limit = connectTimeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waiters[token] = { continuation.resume(with: $0) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                guard let self, let resume = self.waiters.removeValue(forKey: token) else { return }
                resume(.failure(JitsiError.timeout("waiting for CONNECTION_ESTABLISHED")))
            }
        }
    }

    private func settle(with result: Result<Void, Error>) {
        let pending = waiters
        waiters.removeAll()
        for resume in pending.values {
            resume(result)
        }
    }
}
