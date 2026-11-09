import JitsiCore
import SwiftUI

/// Drop-in meeting screen. The app supplies the destination and the display name; every
/// pixel here is native SwiftUI over `AVSampleBufferDisplayLayer`.
public struct MeetingView: View {
    @StateObject private var model: MeetingModel
    private let connection: ConnectionOptions
    private let conference: ConferenceOptions
    private var onEnded: () -> Void

    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.conference = conference
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: MeetingModel())
    }

    /// For an app that already owns a store (so it can keep the meeting alive across
    /// navigation).
    public init(
        model: MeetingModel,
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.conference = conference
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
                Toast(text: message)
            }

            ControlBar(model: model) {
                await model.leave()
                onEnded()
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await model.start(connection, conference: conference)
        }
    }
}

private struct StatusBar: View {
    let model: MeetingModel

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

    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.footnote)
                .foregroundStyle(.white)
                .padding(10)
                .background(Color(white: 0.15).opacity(0.95))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.bottom, 96)
        }
        .transition(.opacity)
    }
}
