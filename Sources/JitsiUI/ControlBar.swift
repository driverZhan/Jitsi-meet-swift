import JitsiCore
import SwiftUI

/// Mute, camera, quality, chat and hang-up.
public struct ControlBar: View {
    private let model: MeetingModel
    private var onLeave: () async -> Void
    @State private var showsChat = false
    @State private var showsScreenShare = false

    public init(model: MeetingModel, onLeave: @escaping () async -> Void) {
        self.model = model
        self.onLeave = onLeave
    }

    public var body: some View {
        HStack(spacing: 22) {
            Button(action: model.toggleAudio) {
                IconBadge(
                    systemName: model.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                    tint: model.isAudioMuted ? .red : .primary
                )
            }
            .accessibilityLabel(model.isAudioMuted ? "Unmute microphone" : "Mute microphone")

            Button(action: model.toggleVideo) {
                IconBadge(
                    systemName: model.isVideoMuted ? "video.slash.fill" : "video.fill",
                    tint: model.isVideoMuted ? .red : .primary
                )
            }
            .accessibilityLabel(model.isVideoMuted ? "Start camera" : "Stop camera")

            #if canImport(ReplayKit)
            Button {
                model.startScreenShare()
                showsScreenShare = true
            } label: {
                IconBadge(
                    systemName: model.isScreenSharing ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle",
                    tint: model.isScreenSharing ? .green : .primary
                )
            }
            .accessibilityLabel("Share screen")
            #endif

            Menu {
                ForEach([180, 360, 720], id: \.self) { height in
                    Button("\(height)p") { model.setQuality(height) }
                }
            } label: {
                IconBadge(systemName: "gearshape.fill", tint: .primary)
            }
            .accessibilityLabel("Video quality")

            Button {
                showsChat = true
            } label: {
                IconBadge(systemName: "bubble.left.fill", tint: .primary)
            }
            .accessibilityLabel("Chat")

            Spacer()

            Button(role: .destructive) {
                Task { await onLeave() }
            } label: {
                IconBadge(systemName: "phone.down.fill", tint: .red, prominent: true)
            }
            .accessibilityLabel("Leave")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showsChat) {
            ChatView(model: model)
        }
        #if canImport(ReplayKit)
        .sheet(isPresented: $showsScreenShare) {
            ScreenSharePrompt(
                isSharing: model.isScreenSharing,
                onStop: {
                    model.stopScreenShare()
                    showsScreenShare = false
                }
            )
        }
        #endif
    }
}

#if canImport(ReplayKit)
/// Instructions plus the system broadcast picker. iOS requires the user to start the
/// broadcast from this control or from Control Center; the app cannot start it directly.
private struct ScreenSharePrompt: View {
    let isSharing: Bool
    let onStop: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            Text("Share your screen").font(.title3.weight(.semibold))
            Text("Tap the broadcast button, then choose Jitsi Broadcast. Your screen is sent to everyone in the meeting.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            ScreenShareBroadcastPicker()
                .frame(width: 64, height: 64)
            if isSharing {
                Button(role: .destructive) {
                    onStop()
                } label: {
                    Text("Stop sharing")
                }
            }
            Button("Done") { dismiss() }
        }
        .padding(28)
    }
}
#endif

private struct IconBadge: View {
    let systemName: String
    let tint: Color
    var prominent = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: prominent ? 20 : 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: prominent ? 52 : 44, height: prominent ? 44 : 40)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(prominent ? 0.12 : 0.06))
            )
    }
}

/// Chat sheet content; `sendMessage` carries plain text only, which is what the lib's
/// text channel accepts.
public struct ChatView: View {
    private let model: MeetingModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""

    public init(model: MeetingModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.transcript) { line in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.author)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(line.text)
                                    .font(.body)
                            }
                            .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .onChange(of: model.transcript.count) { _ in
                    if let last = model.transcript.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    model.sendChat(draft)
                    draft = ""
                }
                .disabled(draft.isEmpty)
            }
            .padding()
        }
    }
}
