import Foundation

/// Turns a push payload into an `IncomingCall`.
///
/// Both regions need this, from different transports:
///
/// * `chinaMainland` -- an APNs **alert** push (`aps.alert` present, no VoIP push type). The
///   app receives it in `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
///   or in the notification service extension, and forwards `userInfo` here.
/// * `international` -- the `JSONDictionary` from `PKPushRegistry`, decoded the same way so
///   one server payload serves both builds.
///
/// Server payload shape:
///
/// ```json
/// { "jitsi": { "conference": "team-standup", "callerName": "Ada",
///              "callerJid": "ada@example.com", "avatar": "https://…/ada.png",
///              "token": "eyJhbGciOi…" } }
/// ```
public enum CallInviteDecoder {
    public static func decode(_ payload: [AnyHashable: Any]) -> IncomingCall? {
        guard let root = payload["jitsi"] as? [String: Any] ?? payload as? [String: Any],
              let conference = root["conference"] as? String,
              !conference.isEmpty
        else { return nil }

        return IncomingCall(
            conference: conference,
            callerName: root["callerName"] as? String ?? "Guest",
            callerJID: root["callerJid"] as? String,
            avatarURL: root["avatar"] as? String,
            token: root["token"] as? String
        )
    }

    /// The `jitsi` dictionary this decoder accepts, for sending a test invite from a shell.
    public static func encode(_ call: IncomingCall) -> [String: Any] {
        var body: [String: Any] = [
            "conference": call.conference,
            "callerName": call.callerName
        ]
        body["callerJid"] = call.callerJID
        body["avatar"] = call.avatarURL
        body["token"] = call.token
        return ["jitsi": body, callIDKey: call.id]
    }

    static let callIDKey = "jitsiCallID"
}
