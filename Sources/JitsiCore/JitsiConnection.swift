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

    /// Full JID of the XMPP session, available once the connection is established.
    public private(set) var jid: String?

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
        jid = nil
        status = .connecting
        try await engine.connect(options)
        try await waitUntilEstablished()
        jid = try? await engine.connectionJID()
    }

    public func disconnect() async {
        await JitsiMeet.shared.engine?.disconnect()
        jid = nil
        status = .disconnected
    }

    /// Transport timing marks collected while connecting (DNS, BOSH, SASL, MUC). Keys vary
    /// by transport version, so this stays a JSON object.
    public func connectionTimes() async throws -> JSONValue {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.connectionTimes()
    }

    /// Publishes an XEP-0115 caps feature. `submit` republishes presence immediately.
    public func addFeature(_ feature: String, submit: Bool = false) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !feature.isEmpty else { throw JitsiError.invalidArgument("feature is required") }
        try await engine.addConnectionFeature(feature, submit: submit)
    }

    public func removeFeature(_ feature: String, submit: Bool = false) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !feature.isEmpty else { throw JitsiError.invalidArgument("feature is required") }
        try await engine.removeConnectionFeature(feature, submit: submit)
    }

    /// Resumes an XMPP session created elsewhere. The server must still hold the session;
    /// returning means `CONNECTION_ESTABLISHED` arrived.
    public func attach(rid: String, sid: String, jid: String) async throws {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        guard !rid.isEmpty, !sid.isEmpty, !jid.isEmpty else {
            throw JitsiError.invalidArgument("rid, sid and jid are required")
        }
        status = .connecting
        try await engine.attachConnection(rid: rid, sid: sid, jid: jid)
        try await waitUntilEstablished()
        self.jid = try? await engine.connectionJID()
    }

    /// Jingle/XMPP transcripts for support bundles. They carry JWTs, SASL payloads and TURN
    /// credentials, so the engine refuses unless `SDKConfig.debugSignaling` is on; keep that
    /// off in release builds.
    public func logs() async throws -> JSONValue {
        guard let engine = JitsiMeet.shared.engine else { throw JitsiError.engineNotInstalled }
        return try await engine.connectionLogs()
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
