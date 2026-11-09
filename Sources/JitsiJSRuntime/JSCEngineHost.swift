import Foundation
import JavaScriptCore
import JitsiCore
import JitsiMedia

/// Owns the `JSContext` that lib-jitsi-meet runs in.
///
/// Threading rule for this layer: the context is created on, and only ever touched
/// from, `queue`. Everything arriving from outside (Swift API calls, URLSession
/// delegates, capture callbacks) hops onto that queue first.
public final class JSCEngineHost: @unchecked Sendable {
    public typealias EventHandler = (String, JSONValue) -> Void

    let queue = DispatchQueue(label: "com.jitsi.jscontext", qos: .userInitiated)

    private var context: JSContext?
    private var router: NativeRouter?
    private var eventHandler: EventHandler?

    /// Blocks bridged into JS must outlive the call that installs them.
    private var installedBlocks: [Any] = []
    private(set) var lastException: String?

    public init() {}

    // MARK: - Lifecycle

    public func start(backend: MediaBackend, capabilities: MediaCapabilities, environment: HostEnvironment) throws {
        try queue.sync {
            guard let context = JSContext() else {
                throw JitsiError.jsRuntimeUnavailable("JSContext could not be created")
            }
            self.context = context

            context.exceptionHandler = { [weak self] _, exception in
                guard let exception else { return }
                let detail = exception.toString() ?? "unknown JS exception"
                self?.lastException = detail
                NSLog("[jitsi-js] %@ | stack: %@", detail, exception.property("stack")?.toString() ?? "")
            }

            let router = NativeRouter(host: self, backend: backend, capabilities: capabilities, environment: environment)
            self.router = router
            installBridge(in: context, router: router)
            try loadScripts(in: context)

            guard let global = context.globalObject, global.property("__sdkInvoke") != nil else {
                throw JitsiError.jsRuntimeUnavailable("__sdkInvoke missing; shim scripts failed to load: \(lastException ?? "")")
            }
        }
    }

    public func stop() {
        queue.async {
            self.router?.shutdown()
            self.router = nil
            self.context = nil
            self.installedBlocks.removeAll()
        }
    }

    public func setEventHandler(_ handler: EventHandler?) {
        queue.async { self.eventHandler = handler }
    }

    // MARK: - Swift -> JS

    /// Calls `__sdkSettle(method, argsJSON, resolve, reject)`, which wraps `__sdkInvoke`
    /// and attaches its callbacks in the same JS execution. See `00-native.js`.
    public func invoke(_ method: String, args: JSONValue) async throws -> JSONValue {
        guard let argsJSON = try? args.encoded,
              let argsText = String(data: argsJSON, encoding: .utf8) else {
            throw JitsiError.jsEvaluationFailed("could not encode arguments for \(method)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let context = self.context, let global = context.globalObject,
                      global.property("__sdkSettle") != nil else {
                    continuation.resume(throwing: JitsiError.engineNotInstalled)
                    return
                }
                let onSuccess: @convention(block) (JSValue?) -> Void = { value in
                    continuation.resume(with: Self.result(from: value))
                }
                let onFailure: @convention(block) (String?) -> Void = { message in
                    continuation.resume(throwing: JitsiError.remote(message ?? "rejected: \(method)"))
                }
                guard let okBlock = JSValue(object: onSuccess, in: context),
                      let failBlock = JSValue(object: onFailure, in: context) else {
                    continuation.resume(throwing: JitsiError.jsEvaluationFailed("could not bridge promise callbacks"))
                    return
                }
                _ = global.invokeMethod("__sdkSettle", withArguments: [method, argsText, okBlock, failBlock])
            }
        }
    }

    private static func result(from value: JSValue?) -> Result<JSONValue, Error> {
        guard let value, !value.isUndefined else {
            return .success(.null)
        }
        do {
            return .success(try value.jsonValue)
        } catch {
            return .failure(JitsiError.jsEvaluationFailed("unconvertible JS result: \(error)"))
        }
    }

    // MARK: - JS -> Swift

    private func installBridge(in context: JSContext, router: NativeRouter) {
        let receive: @convention(block) (JSValue?) -> Void = { [weak self] raw in
            guard let self, let payload = raw?.toString() else { return }
            // JS may already be on `queue` (called from a native reply); `async` keeps
            // re-entrancy legal instead of risking a `sync` deadlock.
            self.queue.async { self.handleReceive(payload, router: router) }
        }
        let syncReceive: @convention(block) (JSValue?) -> String? = { [weak self] raw in
            guard let self, let payload = raw?.toString() else { return nil }
            return self.handleSyncReceive(payload, router: router)
        }

        guard let receiveValue = JSValue(object: receive, in: context),
              let syncValue = JSValue(object: syncReceive, in: context),
              let global = context.globalObject else {
            NSLog("[jitsi-js] failed to bridge native entry points")
            return
        }
        global.setProperty("__nativeReceive", to: receiveValue)
        global.setProperty("__nativeSyncReceive", to: syncValue)
        installedBlocks.append(contentsOf: [receive, syncReceive])
    }

    private func handleReceive(_ payload: String, router: NativeRouter) {
        guard let request = BridgeRequest(payload) else { return }
        switch request.mode {
        case "call":
            router.call(request) { [weak self] result in
                self?.queue.async {
                    switch result {
                    case .success(let value):
                        self?.deliver("__nativeResolve", [request.id ?? 0, JSONBridge.nativeObject(value)])
                    case .failure(let error):
                        self?.deliver("__nativeReject", [request.id ?? 0, String(describing: error)])
                    }
                }
            }
        case "sync":
            router.sync(request)
        default:
            NSLog("[jitsi-js] unknown bridge mode: \(request.mode)")
        }
    }

    private func handleSyncReceive(_ payload: String, router: NativeRouter) -> String? {
        guard let request = BridgeRequest(payload), let value = router.syncResult(request) else {
            return nil
        }
        guard let data = try? value.encoded else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Native -> JS

    /// Invokes a global JS function with plain Foundation arguments.
    func deliver(_ function: String, _ arguments: [Any]) {
        queue.async {
            guard let context = self.context, let global = context.globalObject,
                  let target = global.property(function) else { return }
            let bridged: [JSValue] = arguments.map { argument in
                switch argument {
                case let value as JSValue: return value
                case is NSNull: return JSValue(nullIn: context)
                case let number as NSNumber: return JSValue(object: number, in: context) ?? JSValue(nullIn: context)
                case let string as String: return JSValue(object: string, in: context) ?? JSValue(nullIn: context)
                case let dict as [String: Any]: return JSValue(object: dict, in: context) ?? JSValue(nullIn: context)
                case let array as [Any]: return JSValue(object: array, in: context) ?? JSValue(nullIn: context)
                default: return JSValue(nullIn: context)
                }
            }
            _ = target.call(withArguments: bridged)
        }
    }

    /// Emits onto a shim channel; JS routes by `channel::name`.
    func emit(channel: String, _ name: String, _ payload: JSONValue) {
        deliver("__nativeEmit", [channel, name, JSONBridge.nativeObject(payload)])
    }

    /// The SDK facade reports conference activity through `sdk.event`.
    func reportSDKEvent(name: String, payload: JSONValue) {
        queue.async { self.eventHandler?(name, payload) }
    }

    // MARK: - Script loading

    /// Loads every shim script in the bundle's `js` folder in filename order. The
    /// numbering in the names is the dependency order (native -> dom -> network ->
    /// webrtc -> globals -> facade -> generated lib-jitsi-meet bundle).
    private func loadScripts(in context: JSContext) throws {
        let folderURL = Bundle.module.url(forResource: "js", withExtension: nil)
            ?? Bundle.module.resourceURL?.appendingPathComponent("js")
        guard let folderURL else {
            throw JitsiError.jsRuntimeUnavailable("js resources missing from the bundle")
        }
        let scripts = ((try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? [])
            .filter { $0.hasSuffix(".js") }
            .sorted()

        guard !scripts.isEmpty else {
            throw JitsiError.jsRuntimeUnavailable("no shim scripts found in \(folderURL.path)")
        }

        for name in scripts {
            let url = folderURL.appendingPathComponent(name)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                throw JitsiError.jsRuntimeUnavailable("could not read \(name)")
            }
            context.evaluateScript(source, withSourceURL: URL(fileURLWithPath: url.path))
            if let lastException, scripts.contains(name), name.hasPrefix("50") {
                // Only the facade is fatal-if-broken; earlier scripts may legitimately
                // leave `window.Olm` etc. unset.
                NSLog("[jitsi-js] evaluated \(name) with pending exception: \(lastException)")
            }
        }
    }
}

/// Decoded envelope of a JS -> native message.
struct BridgeRequest {
    var mode: String
    var id: Double?
    var method: String
    var args: JSONValue

    init?(_ payload: String) {
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONValue(from: data),
              case .object(let object) = decoded else {
            return nil
        }
        switch object["mode"] {
        case .string(let value): mode = value
        default: mode = "call"
        }
        if case .number(let value)? = object["id"] {
            id = value
        } else {
            id = nil
        }
        guard case .string(let method)? = object["method"] else {
            return nil
        }
        self.method = method
        args = object["args"] ?? .object([:])
    }
}
