import JitsiCore
import JitsiUI
import SwiftUI
import UIKit

/// A meeting screen laid out from scratch: no `VideoGrid`, no `ControlBar`, no
/// `MeetingView`. It reads `MeetingSession` for session state, `LevelStore` for the signals
/// the store does not model, and `JitsiConference` for operations the store does not wrap.
public struct DemoMeetingScreen: View {
    @StateObject private var model: MeetingSession
    @StateObject private var levels: LevelStore

    private let connection: ConnectionOptions
    private let conference: ConferenceOptions
    private var onEnded: () -> Void

    @State private var showsChat = false
    @State private var showsConsole = false
    @State private var showsParticipants = false
    @State private var showsPolls = false
    @State private var sharesInvite = false
    @State private var notice: String?
    @State private var dismissedMessage: String?
    @State private var deviceSummary = ""
    /// Remote canvases delivered by the session. The board lays them out freely instead of
    /// feeding a grid, which is exactly what the canvas API is for.
    @State private var canvases: [ParticipantCanvas] = []
    @Environment(\.scenePhase) private var scenePhase

    public init(
        connection: ConnectionOptions,
        conference: ConferenceOptions,
        onEnded: @escaping () -> Void = {}
    ) {
        self.connection = connection
        self.conference = conference
        self.onEnded = onEnded
        _model = StateObject(wrappedValue: MeetingSession())
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
        _model = StateObject(wrappedValue: MeetingSession())
        _levels = StateObject(wrappedValue: levels)
    }

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                board
                if showsConsole {
                    console
                }
            }

            if model.isWaitingInLobby {
                lobbyWaiting
            }

            if case .passwordRequired(let isRetry) = model.phase {
                PasswordPromptView(session: model, isRetry: isRetry)
            }

            if case .ended(let reason) = model.phase, reason != .leftByUser {
                MeetingEndedView(reason: reason, onDone: onEnded)
            }

            VStack(spacing: 10) {
                if model.transcriptionActive, !model.captions.isEmpty {
                    DemoCaptionsOverlay(captions: model.captions)
                }
                if let banner = bannerText {
                    Banner(
                        text: banner,
                        retry: model.canRetryConnection ? { model.retry() } : nil
                    ) {
                        notice = nil
                        dismissedMessage = model.message
                    }
                }
                dock
            }
        }
        .preferredColorScheme(.dark)
        // A meeting keeps the screen awake; when the screen sleeps iOS suspends the app
        // and the capture session stops delivering frames.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: scenePhase) { phase in
            model.setAppActive(phase == .active)
        }
        .task {
            levels.observe()
            deviceSummary = describeDevices(model.devices())
            model.canvasStyle = ParticipantCanvasStyle(videoFillMode: .fill, cornerRadius: 10)
            model.onRemoteCanvasJoined = { canvas in canvases.append(canvas) }
            model.onRemoteCanvasLeft = { id in canvases.removeAll { $0.id == id } }
            let timeLimit = ProcessInfo.processInfo.environment["JITSI_DEMO_TIME_LIMIT"]
                .flatMap(Double.init)
            let viewerOnly = ProcessInfo.processInfo.environment["JITSI_DEMO_VIEWER"] == "1"
            var request = MeetingRequest(
                connection: connection,
                conference: conference,
                capture: viewerOnly ? [] : [.audio, .video],
                meetingTimeLimit: timeLimit
            )
            if let raw = ProcessInfo.processInfo.environment["JITSI_DEMO_CONNECT_TIMEOUT"],
               let seconds = TimeInterval(raw) {
                // `0` disables the deadline entirely, matching the bridge argument semantics.
                request.connection.connectTimeout = seconds > 0 ? seconds : nil
            }
            if ProcessInfo.processInfo.environment["JITSI_DEMO_START_MUTED"] == "1" {
                // Mirrors the prejoin screen: capture first, mute, then join.
                try? await model.start(request)
                try? await model.setAudioMuted(true)
                try? await model.setVideoMuted(true)
                try? await model.join()
            } else {
                try? await model.startAndJoin(request)
            }
            deviceSummary = describeDevices(model.devices())
            if ProcessInfo.processInfo.environment.keys.contains("JITSI_DEMO_STATS") {
                Task { await logAudioStatistics() }
            }
            if let value = ProcessInfo.processInfo.environment["JITSI_DEMO_MUTE_CYCLE"],
               let count = Int(value), count > 0 {
                Task { await cycleMute(count) }
            }
        }
        .sheet(isPresented: $showsChat) {
            ChatView(model: model)
        }
        .sheet(isPresented: $showsParticipants) {
            DemoParticipantsPane(model: model)
        }
        .sheet(isPresented: $showsPolls) {
            DemoPollsPane(model: model)
        }
        .sheet(isPresented: $sharesInvite) {
            if let inviteURL {
                DemoShareSheet(items: [inviteURL])
            }
        }
    }

    // MARK: - Layout

    /// A deliberately non-grid board: the local canvas is the stage, remote canvases float
    /// below it. Positions come from plain geometry, so a host can replace this with drag,
    /// carousel or any other arrangement without touching the media layer.
    private var board: some View {
        GeometryReader { proxy in
            let stageHeight = proxy.size.height * 0.48
            let stageWidth = min(proxy.size.width - 16, stageHeight * 16 / 9)
            let remoteWidth = (proxy.size.width - 24) / 3
            let remoteHeight = remoteWidth * 9 / 16

            model.localCanvas()
                .frame(width: stageWidth, height: stageHeight)
                .position(x: proxy.size.width / 2, y: 8 + stageHeight / 2)

            ForEach(Array(canvases.enumerated()), id: \.element.id) { index, canvas in
                let column = index % 3
                let row = index / 3
                canvas
                    .frame(width: remoteWidth, height: remoteHeight)
                    .position(
                        x: 8 + remoteWidth / 2 + CGFloat(column) * (remoteWidth + 4),
                        y: 16 + stageHeight + remoteHeight / 2
                            + CGFloat(row) * (remoteHeight + 4)
                    )
            }
        }
        .padding(8)
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(model.connectionStatus.rawValue.capitalized)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer()
                if model.isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                }
                Text("\(model.tiles.count)")
                    .font(.footnote.monospacedDigit())
                Button {
                    showsParticipants = true
                } label: {
                    Image(systemName: "person.2.fill")
                }
                .accessibilityLabel("Participants")
                Button {
                    showsConsole.toggle()
                } label: {
                    Image(systemName: showsConsole ? "xmark.rectangle.portrait" : "list.bullet.rectangle")
                }
                .accessibilityLabel("Event console")
            }
            HStack(spacing: 10) {
                MeetingTimerText(session: model)
                    .font(.footnote)
                if let quality = model.quality {
                    Text(quality)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                Spacer()
                if let speaker = levels.dominantSpeaker {
                    Text("Talking: \(shorten(speaker))")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(1)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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

    /// The model knocked in the room's lobby. Two backends use it: a moderator-approved
    /// lobby shows this device in the host's lobby list, while a `waiting-for-host` room
    /// admits it automatically once an authenticated host starts the meeting, so there is
    /// no approval request to look for. lib-jitsi-meet joins the main room either way.
    private var lobbyWaiting: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.white)
            Text(model.isWaitingForHost ? "Waiting for the host" : "Waiting for a moderator")
                .font(.headline)
            Text(model.isWaitingForHost
                 ? "This device is in the lobby and joins as soon as an authenticated host "
                    + "starts the meeting."
                 : "\(conference.userInfo.displayName) is in the lobby. "
                    + "A moderator has to let this device into the room.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.75))
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: 320)
        .background(
            Color(white: 0.16).opacity(0.98),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.55).ignoresSafeArea())
    }

    private var dock: some View {
        HStack(spacing: 16) {
            DockButton(
                systemName: model.isAudioMuted ? "mic.slash.fill" : "mic.fill",
                tint: model.isAudioMuted ? .red : .white
            ) {
                Task { try? await model.toggleAudio() }
            }

            DockButton(
                systemName: model.isVideoMuted ? "video.slash.fill" : "video.fill",
                tint: model.isVideoMuted ? .red : .white
            ) {
                Task { try? await model.toggleVideo() }
            }

            DockButton(
                systemName: model.isHandRaised ? "hand.raised.fill" : "hand.raised",
                tint: model.isHandRaised ? .yellow : .white
            ) {
                model.toggleHand()
            }

            Menu {
                ForEach([180, 360, 720], id: \.self) { height in
                    Button("Resolution \(height)p") { model.setQuality(height) }
                }
                Button(model.isRecording ? "Stop recording" : "Start streaming") { toggleRecording() }
                Button("Polls") { showsPolls = true }
                if inviteURL != nil {
                    Button("Invite") { sharesInvite = true }
                }
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
                    await model.hangUp()
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

    /// The web join URL for the room. The deployment's service URL is the web root, so the
    /// room name is the only path component.
    private var inviteURL: URL? {
        let base = connection.serviceUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !base.isEmpty else { return nil }
        return URL(string: "\(base)/\(conference.name)")
    }

    /// Recording and statistics live on `JitsiConference`, not on the store, so the screen
    /// reaches the façade directly and reports on its own `notice` channel.
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

    /// Env-gated (`JITSI_DEMO_MUTE_CYCLE=<n>`) local mute toggles, so an automated run can
    /// observe the presence update on the other side without tapping the dock.
    private func cycleMute(_ count: Int) async {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        for step in 1...count {
            try? await model.toggleAudio()
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            NSLog("[demo-mute] step=%d muted=%d", step, model.isAudioMuted ? 1 : 0)
        }
    }

    /// Env-gated (`JITSI_DEMO_STATS=1`) periodic RTP counter dump, so an automated run can
    /// prove audio flows in both directions without tapping the gear menu.
    private func logAudioStatistics() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let engine = JitsiMeet.shared.engine,
                  let snapshot = try? await engine.statisticsSnapshot() else { continue }
            let records = snapshot["records"]?.arrayValue ?? []
            let sent = records
                .filter { $0["type"]?.stringValue == "outbound-rtp" && $0["kind"]?.stringValue == "audio" }
                .reduce(0.0) { $0 + ($1["bytesSent"]?.doubleValue ?? 0) }
            let received = records
                .filter { $0["type"]?.stringValue == "inbound-rtp" && $0["kind"]?.stringValue == "audio" }
                .reduce(0.0) { $0 + ($1["bytesReceived"]?.doubleValue ?? 0) }
            // Byte counters keep growing on pure silence (Opus pads the stream), so they cannot
            // prove that anyone can hear anything. Inbound energy can: it only rises when the
            // decoded remote signal carries sound. This WebRTC build reports energy on
            // inbound-rtp but not outbound-rtp, so capture is proved by the peer's line.
            let receivedEnergy = records
                .filter { $0["type"]?.stringValue == "inbound-rtp" && $0["kind"]?.stringValue == "audio" }
                .reduce(0.0) { $0 + ($1["totalAudioEnergy"]?.doubleValue ?? 0) }
            NSLog("[demo-stats] audio sent=%.0f KB received=%.0f KB energy in=%.4f participants=%d",
                  sent / 1024, received / 1024, receivedEnergy, model.tiles.count)
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
                let records = snapshot["records"]?.arrayValue ?? []
                let state = snapshot["connectionState"]?.stringValue ?? "unknown"
                // RTP counters are the direct evidence that media flows in both directions:
                // a JVB session whose local tracks never reached the answer sends zero bytes.
                let audioSent = records
                    .filter { $0["type"]?.stringValue == "outbound-rtp" && $0["kind"]?.stringValue == "audio" }
                    .reduce(0.0) { $0 + ($1["bytesSent"]?.doubleValue ?? 0) }
                let audioReceived = records
                    .filter { $0["type"]?.stringValue == "inbound-rtp" && $0["kind"]?.stringValue == "audio" }
                    .reduce(0.0) { $0 + ($1["bytesReceived"]?.doubleValue ?? 0) }
                let metrics = model.metrics
                let memory = String(format: "%.0f MB", Double(metrics.residentBytes) / 1_048_576)
                let firstFrame = metrics.firstRemoteFrameLatency
                    .map { String(format: "%.0f ms", $0 * 1_000) } ?? "—"
                let thermal: String = {
                    switch metrics.thermalState {
                    case .nominal: return "nominal"
                    case .fair: return "fair"
                    case .serious: return "serious"
                    case .critical: return "critical"
                    @unknown default: return "unknown"
                    }
                }()
                notice = "Statistics: \(records.count) records · peer \(state)\n"
                    + "audio sent \(Int(audioSent / 1024)) KB · received \(Int(audioReceived / 1024)) KB\n"
                    + "CPU \(Int(metrics.cpuPercent))% · RAM \(memory) · thermal \(thermal) · first frame \(firstFrame)"
            } catch {
                notice = error.localizedDescription
            }
        }
    }

    private func describeDevices(_ devices: [DeviceDescriptor]) -> String {
        let cameras = devices.filter { $0.kind == .video }.count
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

/// One dock button. The board draws participants through `ParticipantCanvas` instead.
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
    var retry: (() -> Void)?
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let retry {
                Button("Retry", action: retry)
                    .font(.footnote.weight(.semibold))
            }
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
