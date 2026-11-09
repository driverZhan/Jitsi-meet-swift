import Foundation
import JitsiCore
import JitsiMedia

/// One native capability group. Modules are looked up by the segment before the first
/// dot (`ws`, `media`, `timer`, ...), but always receive the full method string so a
/// single module can serve several prefixes — `EnvironmentModule` owns `env`, `log`,
/// `storage`, `timer`, `crypto`, `sdk` and `worker`.
protocol NativeModule: AnyObject {
    var prefixes: [String] { get }

    /// Dispatches by full method name; the default implementation matches the prefix.
    func handles(_ method: String) -> Bool

    func call(_ method: String, _ args: JSONValue, _ reply: @escaping (Result<JSONValue, Error>) -> Void)
    func sync(_ method: String, _ args: JSONValue)
    func syncResult(_ method: String, _ args: JSONValue) -> JSONValue?
}

extension NativeModule {
    func sync(_: String, _: JSONValue) {}
    func syncResult(_ _: String, _ _: JSONValue) -> JSONValue? { nil }

    func handles(_ method: String) -> Bool {
        guard let dot = method.firstIndex(of: ".") else { return false }
        return prefixes.contains(String(method[..<dot]))
    }
}

/// Routes bridge requests to modules. Everything here already runs on the JS queue.
final class NativeRouter {
    private let host: JSCEngineHost
    private var modules: [NativeModule] = []

    let environment: EnvironmentModule
    let network: NetworkModule
    let media: MediaModule

    init(host: JSCEngineHost, backend: MediaBackend, capabilities: MediaCapabilities, environment env: HostEnvironment) {
        self.host = host
        environment = EnvironmentModule(host: host, environment: env, capabilities: capabilities)
        network = NetworkModule(host: host)
        media = MediaModule(host: host, backend: backend, capabilities: capabilities)
        modules = [environment, network, media]
    }

    func call(_ request: BridgeRequest, _ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        guard let module = find(request.method) else {
            reply(.failure(JitsiError.unsupported("no native module for \(request.method)")))
            return
        }
        module.call(request.method, request.args, reply)
    }

    func sync(_ request: BridgeRequest) {
        find(request.method)?.sync(request.method, request.args)
    }

    func syncResult(_ request: BridgeRequest) -> JSONValue? {
        find(request.method)?.syncResult(request.method, request.args)
    }

    func shutdown() {
        network.shutdown()
        media.shutdown()
    }

    private func find(_ method: String) -> NativeModule? {
        modules.first { $0.handles(method) }
    }
}

/// `env.*`, `log.*`, `storage.*`, `timer.*`, `crypto.*`, `media.canPlayType`, `sdk.event`.
///
/// Timers exist because JavaScriptCore ships without `setTimeout`, while lib-jitsi-meet's
/// reconnect backoff, ICE retries and stats polling all depend on it. `storage.get` and
/// `env.describe` must answer synchronously: the settings/feature-flag layer reads
/// `localStorage` inline and cannot await.
final class EnvironmentModule: NativeModule {
    let prefixes = ["env", "log", "storage", "timer", "crypto", "sdk", "worker", "media"]

    private weak var host: JSCEngineHost?
    private var environment: HostEnvironment
    private let capabilities: MediaCapabilities
    private let defaults = UserDefaults(suiteName: "jitsi.js.storage") ?? .standard

    private var timers: [Double: DispatchSourceTimer] = [:]
    private let timerLock = NSLock()

    init(host: JSCEngineHost, environment: HostEnvironment, capabilities: MediaCapabilities) {
        self.host = host
        self.environment = environment
        self.capabilities = capabilities
    }

    /// `media.canPlayType` belongs here; the rest of `media.*` is the media module's.
    func handles(_ method: String) -> Bool {
        if method == "media.canPlayType" {
            return true
        }
        if method.hasPrefix("media.") {
            return false
        }
        return prefixes.contains(String(method.prefix { $0 != "." }))
    }

    func call(_ method: String, _ args: JSONValue, _ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        switch method {
        case "env.describe":
            reply(.success(describeValue()))
        default:
            reply(.failure(JitsiError.unsupported("env.call.\(method)")))
        }
    }

    func sync(_ method: String, _ args: JSONValue) {
        switch method {
        case "log.write":
            let level = (args["level"]?.stringValue) ?? "log"
            if let message = args["message"]?.stringValue {
                NSLog("[jitsi-js:\(level)] %@", message)
            }
        case "timer.set":
            setTimer(args)
        case "timer.clear":
            if let id = args["id"]?.doubleValue {
                cancelTimer(id)
            }
        case "storage.set":
            if let key = args["key"]?.stringValue, let value = args["value"]?.stringValue {
                defaults.set(value, forKey: "jitsi.\(key)")
            }
        case "storage.remove":
            if let key = args["key"]?.stringValue {
                defaults.removeObject(forKey: "jitsi.\(key)")
            }
        case "storage.clear":
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("jitsi.") {
                defaults.removeObject(forKey: key)
            }
        case "sdk.event":
            if let name = args["name"]?.stringValue {
                host?.reportSDKEvent(name: name, payload: args["payload"] ?? .object([:]))
            }
        case "worker.eval", "worker.message", "worker.close", "worker.bootstrap":
            NSLog("[jitsi-js] the Worker bridge is not wired yet (phase 4: E2EE)")
        default:
            break
        }
    }

    func syncResult(_ method: String, _ args: JSONValue) -> JSONValue? {
        switch method {
        case "env.describe":
            return describeValue()
        case "storage.get":
            guard let key = args["key"]?.stringValue else { return nil }
            let value = defaults.string(forKey: "jitsi.\(key)")
            return .object(["value": value.map(JSONValue.string) ?? .null])
        case "crypto.randomUUID":
            return .object(["uuid": .string(UUID().uuidString)])
        case "crypto.randomBytes":
            let length = max(1, Int(args["length"]?.doubleValue ?? 16))
            let bytes = (0..<length).map { _ in JSONValue.number(Double(UInt8.random(in: 0...255))) }
            return .object(["bytes": .array(bytes)])
        case "media.canPlayType":
            guard let mimeType = args["mimeType"]?.stringValue else {
                return .object(["proficient": .bool(false)])
            }
            let name = (mimeType.split(whereSeparator: { "/;".contains($0) })[safe: 1] ?? Substring(mimeType))
                .lowercased()
            let supported = capabilities.videoCodecs.contains(name)
                || capabilities.audioCodecs.contains(name)
                || mimeType.contains("opus")
                || mimeType.contains("vp8")
            return .object(["proficient": .bool(supported)])
        default:
            return nil
        }
    }

    private func describeValue() -> JSONValue {
        .object([
            "userAgent": .string(environment.userAgent),
            "platform": .string(environment.platform),
            "hostname": .string(environment.hostname),
            "origin": .string(environment.origin),
            "language": .string(environment.language),
            "screenWidth": .number(Double(environment.screenWidth)),
            "screenHeight": .number(Double(environment.screenHeight)),
            "scale": .number(environment.scale),
            "cpuCount": .number(Double(environment.cpuCount)),
            "online": .bool(environment.online),
            "visible": .bool(environment.visible),
            "mediaBackendReady": .bool(environment.mediaBackendReady),
            "reactNativeVersion": .string(environment.reactNativeVersion)
        ])
    }

    func updateVisibility(_ visible: Bool) {
        environment.visible = visible
        host?.emit(channel: "env", "visibility", .object(["visible": .bool(visible)]))
    }

    // MARK: - Timers

    private func setTimer(_ args: JSONValue) {
        guard let host, let id = args["id"]?.doubleValue, let delay = args["delay"]?.doubleValue else { return }
        let repeats = args["repeat"]?.boolValue ?? false
        let interval = max(0.001, delay / 1000.0)

        let source = DispatchSource.makeTimerSource(queue: host.queue)
        if repeats {
            source.schedule(deadline: .now() + interval, repeating: interval)
        } else {
            source.schedule(deadline: .now() + interval)
        }
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if !repeats {
                self.cancelTimer(id)
            }
            self.host?.emit(channel: "timer", "fire", .object(["id": .number(id)]))
        }
        timerLock.lock()
        timers[id]?.cancel()
        timers[id] = source
        timerLock.unlock()
        source.resume()
    }

    private func cancelTimer(_ id: Double) {
        timerLock.lock()
        let source = timers.removeValue(forKey: id)
        timerLock.unlock()
        source?.cancel()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
