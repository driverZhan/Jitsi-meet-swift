import JitsiCore
import SwiftUI

/// Drop-in meeting screen. The app supplies the destination and the display name; every
/// pixel here is native SwiftUI over `AVSampleBufferDisplayLayer`.
public struct MeetingView: View {
    @StateObject private var model: MeetingSession
    /// Non-nil only for the self-starting form. `MeetingContainer` owns the lifecycle in
    /// every other case, so the room must not connect a second time.
    private let request: MeetingRequest?
    private var onEnded: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) {
        self.request = MeetingRequest(connection: connection, conference: conference)
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: MeetingSession())
    }

    /// Renders the room for a session someone else already started.
    public init(model: MeetingSession, onEnded: @escaping () -> Void = {}) {
        self.request = nil
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VideoGrid(model: model)

            VStack {
                StatusBar(model: model)
                Spacer()
            }

            if let message = model.message {
                Toast(
                    text: message,
                    retry: model.canRetryConnection ? { model.retry() } : nil
                )
            }

            ControlBar(model: model) {
                await model.hangUp()
                onEnded()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            guard let request else { return }
            try? await model.startAndJoin(request)
        }
        .onChange(of: scenePhase) { phase in
            model.setAppActive(phase == .active)
        }
    }
}

private struct StatusBar: View {
    let model: MeetingSession

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: model.connectionStatus)
            Text(model.connectionStatus.rawValue.capitalized)
                .font(.footnote)
            Spacer()
            if model.isRecording {
                Label("Recording", systemImage: "record.circle")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Text("\(model.tiles.count)")
                .font(.footnote.monospacedDigit())
            Image(systemName: "person.2.fill")
                .font(.footnote)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal)
    }
}

private struct StatusDot: View {
    let status: ConnectionStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        switch status {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected, .idle: return .gray
        case .error: return .red
        }
    }
}

private struct Toast: View {
    let text: String
    var retry: (() -> Void)?

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Text(text)
                    .font(.footnote)
                if let retry {
                    Button("Retry", action: retry)
                        .font(.footnote.weight(.semibold))
                }
            }
            .foregroundStyle(.white)
            .padding(10)
            .background(Color(white: 0.15).opacity(0.95))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.bottom, 96)
        }
        .transition(.opacity)
    }
}
