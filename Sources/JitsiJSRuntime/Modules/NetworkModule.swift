import Foundation
import JitsiCore

/// `ws.*` and `http.*` over URLSession.
///
/// WebSocket is load-bearing, not optional: XMPP stream management uses it and the JVB
/// bridge channel falls back to colibri-ws when SCTP data channels are unavailable.
final class NetworkModule: NativeModule {
    let prefixes = ["ws", "http"]

    private weak var host: JSCEngineHost?
    private let session: URLSession
    private var sockets: [String: URLSessionWebSocketTask] = [:]
    private var requests: [String: URLSessionDataTask] = [:]
    private var requestCounter = 1
    private let lock = NSLock()

    init(host: JSCEngineHost) {
        self.host = host
        let configuration = URLSessionConfiguration.default
        // BOSH long-polling holds a POST open for the server's `wait` (60 s by default), so a
        // request timeout below that turns every idle poll into a transport error.
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)
    }

    func call(_ method: String, _ args: JSONValue, _ reply: @escaping (Result<JSONValue, Error>) -> Void) {
        reply(.failure(JitsiError.unsupported("network.call.\(method): use the synchronous entry point")))
    }

    /// `ws.open` and `http.send` are called synchronously from JS so the object graphs
    /// (WebSocket, XHR) can hand back an identity in the same tick.
    func syncResult(_ method: String, _ args: JSONValue) -> JSONValue? {
        switch method {
        case "ws.open":
            guard case .string(let urlText)? = args["url"], let url = URL(string: urlText) else { return nil }
            return openSocket(url, protocols: args["protocols"]?.arrayValue.compactMap { $0.stringValue } ?? [])
        case "http.send":
            return sendRequest(args)
        default:
            return nil
        }
    }

    func sync(_ method: String, _ args: JSONValue) {
        switch method {
        case "ws.send":
            guard let id = args["id"]?.stringValue, let socket = sockets[id] else { return }
            if let text = args["text"]?.stringValue {
                socket.send(.string(text)) { _ in }
            } else if let base64 = args["bytesBase64"]?.stringValue, let data = Data(base64Encoded: base64) {
                socket.send(.data(data)) { _ in }
            }
        case "ws.close":
            guard let id = args["id"]?.stringValue, let socket = sockets[id] else { return }
            let code = UInt16(args["code"]?.doubleValue ?? 1000)
            socket.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: Int(code)) ?? .normalClosure,
                         reason: args["reason"]?.stringValue.map { Data($0.utf8) })
        case "http.abort":
            if let id = args["id"]?.stringValue {
                lock.lock()
                let task = requests.removeValue(forKey: id)
                lock.unlock()
                task?.cancel()
            }
        default:
            break
        }
    }

    func shutdown() {
        for socket in sockets.values {
            socket.cancel(with: .goingAway, reason: nil)
        }
        sockets.removeAll()
        for task in requests.values {
            task.cancel()
        }
        requests.removeAll()
    }

    // MARK: - WebSocket

    private func openSocket(_ url: URL, protocols: [String]) -> JSONValue? {
        var request = URLRequest(url: url)
        if let first = protocols.first {
            request.setValue(first, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        }
        let socket = session.webSocketTask(with: request)
        let id = "ws-\(requestCounter)"
        requestCounter += 1
        sockets[id] = socket
        socket.resume()
        listen(id, socket)
        return .object(["id": .string(id)])
    }

    private func listen(_ id: String, _ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.host?.emit(channel: "ws:\(id)", "message", .object(["text": .string(text)]))
                case .data(let data):
                    self.host?.emit(channel: "ws:\(id)", "message", .object([
                        // Binary frames reach the bridge channel as base64; the JS side
                        // converts to the typed array the colibri protocol expects.
                        "bytes": .string(data.base64EncodedString())
                    ]))
                @unknown default:
                    break
                }
                self.listen(id, socket)
            case .failure(let error):
                let closed = (error as? URLError)?.code == .cancelled
                self.host?.emit(channel: "ws:\(id)", closed ? "close" : "error", .object([
                    "code": .number(closed ? 1000 : 1006),
                    "reason": .string(error.localizedDescription)
                ]))
                self.host?.queue.async {
                    self.sockets[id] = nil
                }
            }
        }
    }

    // MARK: - HTTP

    private func sendRequest(_ args: JSONValue) -> JSONValue? {
        guard case .string(let urlText)? = args["url"], let url = URL(string: urlText) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = (args["method"]?.stringValue ?? "GET").uppercased()
        if let headers = args["headers"]?.objectValue {
            for (name, value) in headers {
                request.setValue(value.stringValue, forHTTPHeaderField: name)
            }
        }
        request.httpBody = args["body"]?.stringValue?.data(using: .utf8)
        if let timeout = args["timeout"]?.doubleValue, timeout > 0 {
            request.timeoutInterval = timeout / 1000
        }

        let id = "http-\(requestCounter)"
        requestCounter += 1
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.lock.lock()
            self.requests[id] = nil
            self.lock.unlock()

            if let error {
                self.host?.emit(channel: "http:\(id)", "failure", .object(["message": .string(error.localizedDescription)]))
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            var payload: [String: JSONValue] = [
                "status": .number(Double(http.statusCode)),
                "statusText": .string(HTTPURLResponse.localizedString(forStatusCode: http.statusCode)),
                "headers": .object(http.allHeaderFields.reduce(into: [:]) { partial, pair in
                    partial[String(describing: pair.key).lowercased()] = .string(String(describing: pair.value))
                })
            ]
            if let data {
                payload["body"] = .string(String(decoding: data, as: UTF8.self))
            }
            self.host?.emit(channel: "http:\(id)", "response", .object(payload))
        }
        lock.lock()
        requests[id] = task
        lock.unlock()
        task.resume()
        // The XHR shim uses this value as the event channel suffix, so it must be the id
        // itself rather than a wrapper object.
        return .string(id)
    }
}
