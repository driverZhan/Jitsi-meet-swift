import Foundation

/// A deployment address in whatever form the integrator has it.
///
/// People paste `meet.example.org`, `meet.example.org:8443` or the whole
/// `https://meet.example.org:8443` from a browser. Deriving every endpoint from one parse keeps
/// the transport URL, the XMPP domain and the MUC domain from drifting apart; concatenating
/// `"wss://" + host` breaks as soon as the input carries a scheme or a port.
///
/// The transport URL and the XMPP domain are not the same thing on a self-hosted deployment:
/// docker-jitsi-meet serves `/http-bind` and `/xmpp-websocket` on the public host while Prosody
/// answers as `meet.jitsi` and hosts MUC at `muc.meet.jitsi`.
public struct ServerAddress: Sendable, Equatable {
    public enum Transport: String, Sendable, Equatable {
        case websocket
        case bosh
    }

    /// XMPP domain: no scheme, no port.
    public let domain: String
    /// `domain[:port]`, what the JS `location.host` shim should report.
    public let host: String
    /// `https://domain[:port]`; `http://` when the input asked for it.
    public let origin: String
    /// The URL Strophe connects to: `…/xmpp-websocket` or `…/http-bind`.
    public let serviceUrl: String
    /// MUC domain, `conference.<domain>` unless the deployment says otherwise.
    public let muc: String

    public init(
        _ input: String,
        transport: Transport = .websocket,
        domain overrideDomain: String? = nil,
        muc overrideMuc: String? = nil
    ) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        let components = URLComponents(string: candidate)
        let secure = (components?.scheme ?? "https").lowercased() != "http"
        let parsed = components?.host ?? ""
        let parsedHost = parsed.isEmpty
            ? (trimmed.split(separator: "/").first.map(String.init) ?? trimmed)
            : parsed
        let port = components?.port.map { ":\($0)" } ?? ""
        // URLComponents drops the brackets around an IPv6 literal; a URL needs them back.
        let urlHost = parsedHost.contains(":") && !parsedHost.hasPrefix("[") ? "[\(parsedHost)]" : parsedHost
        let basePath = (components?.path ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let xmppDomain = overrideDomain?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        domain = xmppDomain.isEmpty ? parsedHost : xmppDomain
        host = parsedHost + port
        origin = "\(secure ? "https" : "http")://\(urlHost)\(port)"

        let endpoint = transport == .bosh ? "http-bind" : "xmpp-websocket"
        let path = basePath.isEmpty ? endpoint : (basePath.hasSuffix(endpoint) ? basePath : "\(basePath)/\(endpoint)")
        switch transport {
        case .websocket:
            serviceUrl = "\(secure ? "wss" : "ws")://\(urlHost)\(port)/\(path)"
        case .bosh:
            serviceUrl = "\(secure ? "https" : "http")://\(urlHost)\(port)/\(path)"
        }

        let mucOverride = overrideMuc?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        muc = mucOverride.isEmpty ? "conference.\(domain)" : mucOverride
    }
}
