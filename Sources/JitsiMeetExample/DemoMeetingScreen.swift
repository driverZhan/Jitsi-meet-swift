import JitsiCore
import JitsiUI
import SwiftUI
import UIKit

/// A meeting screen laid out from scratch: no `VideoGrid`, no `ControlBar`, no
/// `MeetingView`. It reads `MeetingModel` for session state, `LevelStore` for the signals
/// the store does not model, and `JitsiConference` for operations the store does not wrap.
public struct DemoMeetingScreen: View {
    @StateObject private var model: MeetingModel
    @StateObject private var levels: LevelStore

    private let connection: ConnectionOptions
    private let conference: ConferenceOptions
    private var onEnded: () -> Void

    @State private var showsChat = false
    @State private var showsConsole = false
    @State private var handRaised = false
    @State private var notice: String?
    @State private var dismissedMessage: String?
    @State private var deviceSummary = ""

    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.conference = conference
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: MeetingModel())
        _levels = StateObject(wrappedValue: LevelStore())
    }

    /// For a host that owns the level store, e.g. to keep the audio ring alive across
    /// navigation.
    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        levels: LevelStore,
        onEnded: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.conference = conference
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: MeetingModel())
        _levels = StateObject(wrappedValue: levels)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                grid
                if showsConsole {
                    console
                }
            }

            VStack(spacing: 10) {
                if let banner = bannerText {
                    Banner(text: banner) { notice = nil; dismissedMessage = model.message }
                }
                dock
            }
        }
        .preferredColorScheme(.dark)
        // A meeting keeps the screen awake; when the screen sleeps iOS suspends the app
        // and the capture session stops delivering frames.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .task {
            levels.observe()
            deviceSummary = describeDevices(model.devices())
            await model.start(connection, conference: conference)
            deviceSummary = describeDevices(model.devices())
        }
        .sheet(isPresented: $showsChat) {
            ChatView(model: model)
        }
    }

    // MARK: - Layout

    /// 1 / 2 / 3 columns by headcount, every cell the same size.
    private var columns: [GridItem] {
        let count = model.tiles.count
        let perRow = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: perRow)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(model.tiles) { tile in
                    DemoTile(tile: tile, model: model, levels: levels)
                }
            }
            .padding(8)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.connectionStatus.rawValue.capitalized)
                .font(.footnote)
            if let quality = model.quality {
                Text(quality)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            if let speaker = levels.dominantSpeaker {
                Text("Talking: \(shorten(speaker))")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            if model.isRecording {
                Image(systemName: "record.circle")
                    .foregroundStyle(.red)
            }
            Text("\(model.tiles.count)")
                .font(.footnote.monospacedDigit())
            Button {
                showsConsole.toggle()
            } label: {
                Image(systemName: showsConsole ? "xmark.rectangle.portrait" : "list.bullet.rectangle")
            }
            .accessibilityLabel("Event console")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private var console: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Events")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(deviceSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let rooms = levels.lastBreakoutRooms {
                Text("breakoutRoomsUpdated: \(String(describing: rooms))")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(2)
            }
            if !levels.mutedParticipants.isEmpty {
                Text("muted remotely: \(levels.mutedParticipants.sorted().joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(levels.log.indices, id: \.self) { index in
                            Text(levels.log[index])
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.8))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: levels.log.count) { count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(10)
        .frame(maxWidth: .infinity)
        .frame(height: 170)
        .background(Color.white.opacity(0.06))
    }

    private var dock: some View {
        HStack(spacing: 16) {
            DockButton(
                systemName: model.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                tint: model.isAudioMuted ? .red : .white
            ) {
                model.toggleAudio()
            }

            DockButton(
                systemName: model.isVideoMuted ? "video.slash.fill" : "video.fill",
                tint: model.isVideoMuted ? .red : .white
            ) {
                model.toggleVideo()
            }

            DockButton(
                systemName: handRaised ? "hand.raised.fill" : "hand.raised",
                tint: handRaised ? .yellow : .white
            ) {
                toggleHand()
            }

            Menu {
                ForEach([180, 360, 720], id: \.self) { height in
                    Button("Resolution \(height)p") { model.setQuality(height) }
                }
                Button(model.isRecording ? "Stop recording" : "Start streaming") { toggleRecording() }
                Button("Fetch statistics") { fetchStatistics() }
            } label: {
                DockIcon(systemName: "gearshape.fill", tint: .white)
            }
            .accessibilityLabel("More")

            DockButton(systemName: "bubble.left.fill", tint: .white) {
                showsChat = true
            }

            Spacer(minLength: 4)

            DockButton(systemName: "phone.down.fill", tint: .white, background: Color.red) {
                Task {
                    levels.stopObserving()
                    await model.leave()
                    onEnded()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: - Actions outside the store

    private var bannerText: String? {
        if let notice { return notice }
        if let message = model.message, message != dismissedMessage { return message }
        return nil
    }

    /// Raise hand, recording and statistics live on `JitsiConference`, not on the store,
    /// so the screen reaches the façade directly and reports on its own `notice` channel.
    private func toggleHand() {
        guard let room = model.conference else {
            notice = "Join the conference first."
            return
        }
        let next = !handRaised
        Task {
            do {
                try await room.raiseHand(next)
                handRaised = next
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func toggleRecording() {
        guard let room = model.conference else {
            notice = "Join the conference first."
            return
        }
        Task {
            do {
                if model.isRecording {
                    try await room.stopRecording()
                } else {
                    try await room.startRecording(RecordingOptions(mode: .stream))
                }
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func fetchStatistics() {
        guard let engine = JitsiMeet.shared.engine else {
            notice = "The meeting engine is not installed. Call JitsiMeetSDK.bootstrap() first."
            return
        }
        Task {
            do {
                let snapshot = try await engine.statisticsSnapshot()
                let records = snapshot["records"]?.arrayValue.count ?? 0
                let state = snapshot["connectionState"]?.stringValue ?? "unknown"
                notice = "Statistics: \(records) records, peer state \(state)"
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func describeDevices(_ devices: [DeviceDescriptor]) -> String {        let cameras = devices.filter { $0.kind == .video }.count
        let microphones = devices.filter { $0.kind == .audio }.count
        return "\(cameras) cameras, \(microphones) microphones"
    }

    private func shorten(_ participantID: ParticipantID) -> String {
        String(participantID.prefix(6))
    }

    private var statusColor: Color {
        switch model.connectionStatus {
        case .connected: return .green
        case .connecting: return .yellow
        case .disconnected, .idle: return .gray
        case .error: return .red
        }
    }
}

/// One cell: native pixels when there is a live camera, an avatar otherwise, and a ring
/// driven by the audio-level events the store does not expose on `Tile`.
struct DemoTile: View {
    let tile: MeetingModel.Tile
    let model: MeetingModel
    @ObservedObject var levels: LevelStore

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let trackID = visibleTrackID {
                VideoSurface(frames: model.frames(for: trackID), mirrored: tile.isLocal)
            } else {
                avatar
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if tile.audioMuted {
                        Image(systemName: "mic.slash.fill")
                            .foregroundStyle(.red)
                    }
                    Text(tile.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(.white)
            .shadow(radius: 2)
            .padding(8)

            if tile.raisedHand {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.yellow)
                            .padding(8)
                    }
                    Spacer()
                }
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(ring)
    }

    private var visibleTrackID: TrackID? {
        tile.videoTrackID
    }

    private var avatar: some View {
        ZStack {
            Color(white: 0.13)
            Text(initials)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var initials: String {
        let parts = tile.displayName.split(separator: " ").prefix(2)
        let letters = parts.map { String($0.prefix(1)) }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private var ring: some View {
        let speaking = levels.isSpeaking(tile.id)
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(
                (tile.isDominantSpeaker && speaking ? Color.green : Color.clear),
                lineWidth: speaking ? 3 : 0
            )
            .animation(.easeOut(duration: 0.12), value: speaking)
    }
}

private struct DockButton: View {
    let systemName: String
    let tint: Color
    var background: Color?
    var action: () -> Void

    init(systemName: String, tint: Color, background: Color? = nil, action: @escaping () -> Void) {
        self.systemName = systemName
        self.tint = tint
        self.background = background
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            DockIcon(systemName: systemName, tint: tint, background: background)
        }
        .accessibilityLabel(systemName)
    }
}

private struct DockIcon: View {
    let systemName: String
    let tint: Color
    var background: Color?

    init(systemName: String, tint: Color, background: Color? = nil) {
        self.systemName = systemName
        self.tint = tint
        self.background = background
    }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 44, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(background ?? Color.primary.opacity(0.08))
            )
    }
}

private struct Banner: View {
    let text: String
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.6))
            }
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.white)
        .padding(10)
        .background(Color(white: 0.16).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
    }
}
