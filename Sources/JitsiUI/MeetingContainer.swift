import JitsiCore
import SwiftUI

/// Replacement screens for the join flow. Every slot is optional: `MeetingLayout.standard`
/// renders the built-in prejoin, lobby, password, ended and failure screens, and an app can
/// swap any single one without reimplementing the rest.
public struct MeetingLayout {
    public var prejoin: ((MeetingSession) -> AnyView)?
    public var waitingInLobby: ((MeetingSession, LobbyAdmission) -> AnyView)?
    public var password: ((MeetingSession, _ isRetry: Bool) -> AnyView)?
    /// Replaces the whole in-room surface. A custom room owns its own hang-up control.
    public var room: ((MeetingSession) -> AnyView)?
    public var ended: ((MeetingSession, MeetingEndReason) -> AnyView)?
    public var failed: ((MeetingSession, _ message: String) -> AnyView)?

    public init(
        prejoin: ((MeetingSession) -> AnyView)? = nil,
        waitingInLobby: ((MeetingSession, LobbyAdmission) -> AnyView)? = nil,
        password: ((MeetingSession, _ isRetry: Bool) -> AnyView)? = nil,
        room: ((MeetingSession) -> AnyView)? = nil,
        ended: ((MeetingSession, MeetingEndReason) -> AnyView)? = nil,
        failed: ((MeetingSession, _ message: String) -> AnyView)? = nil
    ) {
        self.prejoin = prejoin
        self.waitingInLobby = waitingInLobby
        self.password = password
        self.room = room
        self.ended = ended
        self.failed = failed
    }

    public static let standard = MeetingLayout()
}

/// The whole meeting as one view: connect → prejoin → join → lobby/password → room →
/// reconnect → ended. This is the single-entry replacement for driving
/// `bootstrap`/`connect`/`join` from the app.
///
/// The session stays owned by the container, so the flow survives view updates. Pass an
/// existing session instead of a request when the host wants to keep it (e.g. to re-present
/// the room after navigation).
public struct MeetingContainer: View {
    @StateObject private var session: MeetingSession
    private let request: MeetingRequest?
    private let layout: MeetingLayout
    private let autoJoin: Bool
    private let onEnded: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    /// - Parameters:
    ///   - autoJoin: `true` skips the prejoin screen and joins as soon as capture is open.
    ///     The default keeps the prejoin step, where the user can fix permissions, devices
    ///     and mute state before publishing anything.
    public init(
        request: MeetingRequest,
        layout: MeetingLayout = .standard,
        autoJoin: Bool = false,
        onEnded: @escaping () -> Void = {}
    ) {
        _session = StateObject(wrappedValue: MeetingSession())
        self.request = request
        self.layout = layout
        self.autoJoin = autoJoin
        self.onEnded = onEnded
    }

    /// For a host that already called `start` (or is reusing a session across screens).
    public init(
        session: MeetingSession,
        layout: MeetingLayout = .standard,
        onEnded: @escaping () -> Void = {}
    ) {
        _session = StateObject(wrappedValue: session)
        self.request = nil
        self.autoJoin = false
        self.layout = layout
        self.onEnded = onEnded
    }

    public var body: some View {
        Group {
            switch session.phase {
            case .idle, .connecting:
                LoadingScreen(title: "Connecting…", detail: session.message)
            case .ready:
                prejoin
            case .joining:
                LoadingScreen(title: "Joining…", detail: nil)
            case .waitingInLobby(let admission):
                lobby(admission)
            case .passwordRequired(let isRetry):
                password(isRetry)
            case .joined, .reconnecting:
                room
            case .ended(let reason):
                ended(reason)
            case .failed(let message):
                failed(message)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard let request else { return }
            do {
                try await session.start(request)
                if autoJoin, session.phase == .ready {
                    try await session.join()
                }
            } catch {
                // `start`/`join` already wrote the failure into `message` and `phase`.
            }
        }
        .onChange(of: session.phase) { phase in
            // A local hang-up leaves the flow instead of showing an "you left" screen.
            if case .ended(.leftByUser) = phase {
                onEnded()
            }
        }
        .onChange(of: scenePhase) { phase in
            session.setAppActive(phase == .active)
        }
    }

    @ViewBuilder
    private var prejoin: some View {
        if let prejoin = layout.prejoin {
            prejoin(session)
        } else {
            PrejoinView(session: session)
        }
    }

    @ViewBuilder
    private func lobby(_ admission: LobbyAdmission) -> some View {
        if let waiting = layout.waitingInLobby {
            waiting(session, admission)
        } else {
            LobbyWaitingView(session: session, admission: admission)
        }
    }

    @ViewBuilder
    private func password(_ isRetry: Bool) -> some View {
        if let password = layout.password {
            password(session, isRetry)
        } else {
            PasswordPromptView(session: session, isRetry: isRetry)
        }
    }

    @ViewBuilder
    private var room: some View {
        if let room = layout.room {
            room(session)
        } else {
            MeetingView(model: session)
        }
    }

    @ViewBuilder
    private func ended(_ reason: MeetingEndReason) -> some View {
        if let ended = layout.ended {
            ended(session, reason)
        } else {
            MeetingEndedView(reason: reason, onDone: onEnded)
        }
    }

    @ViewBuilder
    private func failed(_ message: String) -> some View {
        if let failed = layout.failed {
            failed(session, message)
        } else {
            MeetingFailureView(session: session, message: message, onClose: onEnded)
        }
    }
}

/// Camera preview plus microphone/camera controls, shown between connecting and joining.
public struct PrejoinView: View {
    @ObservedObject private var session: MeetingSession

    public init(session: MeetingSession) {
        _session = ObservedObject(wrappedValue: session)
    }

    public var body: some View {
        VStack(spacing: 18) {
            Text("Ready to join?")
                .font(.title3.weight(.semibold))

            TrackVideo(
                model: session,
                trackID: session.localVideoTrackID,
                mirrored: session.localMedia.isFrontCamera
            )
            .frame(maxHeight: .infinity)

            if let name = session.request?.conference.userInfo.displayName, !name.isEmpty {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                PrejoinToggle(
                    systemName: session.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                    muted: session.isAudioMuted
                ) {
                    session.runControl { try await session.toggleAudio() }
                }
                PrejoinToggle(
                    systemName: session.isVideoMuted ? "video.slash.fill" : "video.fill",
                    muted: session.isVideoMuted
                ) {
                    session.runControl { try await session.toggleVideo() }
                }
                Button {
                    session.runControl { try await session.switchCamera() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 40)
                }
                .accessibilityLabel("Switch camera")
            }
            .foregroundStyle(.primary)

            if let message = session.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 14) {
                Button("Cancel") {
                    Task { await session.cancelJoin() }
                }
                .buttonStyle(.bordered)

                Button("Join") {
                    Task { try? await session.join() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.phase != .ready)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

/// Waiting outside a members-only room, either for a moderator or for the host to start.
public struct LobbyWaitingView: View {
    @ObservedObject private var session: MeetingSession
    private let admission: LobbyAdmission

    public init(session: MeetingSession, admission: LobbyAdmission) {
        _session = ObservedObject(wrappedValue: session)
        self.admission = admission
    }

    public var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(admission == .waitingForHost
                ? "Waiting for the host to start the meeting"
                : "Waiting for a moderator to let you in")
                .font(.headline)
            if let message = session.message, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Cancel") {
                Task { await session.cancelJoin() }
            }
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

/// Password entry for a locked room. `isRetry` means the previous password was refused.
public struct PasswordPromptView: View {
    @ObservedObject private var session: MeetingSession
    private let isRetry: Bool
    @State private var password = ""
    @State private var isSubmitting = false

    public init(session: MeetingSession, isRetry: Bool) {
        _session = ObservedObject(wrappedValue: session)
        self.isRetry = isRetry
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 34))
            Text(isRetry ? "Wrong password" : "This meeting is locked")
                .font(.headline)
            Text("Enter the password to join.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .submitLabel(.go)
                .onSubmit(submit)

            HStack(spacing: 14) {
                Button("Cancel") {
                    Task { await session.cancelJoin() }
                }
                .buttonStyle(.bordered)
                Button("Join", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isSubmitting)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }

    private func submit() {
        guard !password.isEmpty, !isSubmitting else { return }
        isSubmitting = true
        let value = password
        Task {
            defer { isSubmitting = false }
            try? await session.submitPassword(value)
        }
    }
}

/// Terminal screen after a kick, a replacement or a destroyed room.
public struct MeetingEndedView: View {
    private let reason: MeetingEndReason
    private let onDone: () -> Void

    public init(reason: MeetingEndReason, onDone: @escaping () -> Void) {
        self.reason = reason
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.down.fill")
                .font(.system(size: 34))
                .foregroundStyle(.red)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }

    private var title: String {
        switch reason {
        case .leftByUser: return "You left the meeting"
        case .kicked: return "You were removed from the meeting"
        case .replacedByAnotherSession: return "Another device joined with your account"
        case .endedByHost: return "The meeting has ended"
        case .connectionLost: return "The connection was lost"
        }
    }

    private var detail: String? {
        switch reason {
        case .kicked(_, let message), .endedByHost(let message):
            return message.isEmpty ? nil : message
        case .leftByUser, .replacedByAnotherSession, .connectionLost:
            return nil
        }
    }
}

/// Non-terminal failure: connect errors, denied lobby requests and refused joins.
public struct MeetingFailureView: View {
    @ObservedObject private var session: MeetingSession
    private let message: String
    private let onClose: () -> Void

    public init(session: MeetingSession, message: String, onClose: @escaping () -> Void) {
        _session = ObservedObject(wrappedValue: session)
        self.message = message
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
            Text("Could not join the meeting")
                .font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 14) {
                Button("Close") {
                    Task {
                        await session.hangUp()
                        onClose()
                    }
                }
                .buttonStyle(.bordered)
                if session.canRetryConnection {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

/// Spinner shown while the engine connects and prepares the room.
public struct LoadingScreen: View {
    private let title: String
    private let detail: String?

    public init(title: String, detail: String?) {
        self.title = title
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92).ignoresSafeArea())
    }
}

private struct PrejoinToggle: View {
    let systemName: String
    let muted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(muted ? .red : .primary)
                .frame(width: 44, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
    }
}
