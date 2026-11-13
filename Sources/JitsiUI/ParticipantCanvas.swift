import JitsiCore
import SwiftUI

/// How a video track fills the canvas rectangle.
public enum VideoFillMode: Sendable {
    /// Crop the frame so the rectangle is covered (no letterboxing).
    case fill
    /// Letterbox so the whole frame stays visible.
    case fit
}

/// The green outline drawn around the active speaker.
public enum SpeakingHighlight: Sendable {
    case none
    case ring
}

/// Appearance of a `ParticipantCanvas`. The session-level default is
/// `MeetingSession.canvasStyle`; a single canvas can override it with
/// `ParticipantCanvas.style(_:)`.
public struct ParticipantCanvasStyle: Sendable {
    public var videoFillMode: VideoFillMode
    public var cornerRadius: CGFloat
    public var avatarSize: CGFloat
    public var showsName: Bool
    /// Red `mic.slash` while muted, the level meter while open.
    public var showsMicrophoneBadge: Bool
    /// The connection-quality bars, pinned to the top-left corner.
    public var showsConnectionBadge: Bool
    public var speakingHighlight: SpeakingHighlight

    public init(
        videoFillMode: VideoFillMode = .fill,
        cornerRadius: CGFloat = 12,
        avatarSize: CGFloat = 64,
        showsName: Bool = true,
        showsMicrophoneBadge: Bool = true,
        showsConnectionBadge: Bool = true,
        speakingHighlight: SpeakingHighlight = .ring
    ) {
        self.videoFillMode = videoFillMode
        self.cornerRadius = cornerRadius
        self.avatarSize = avatarSize
        self.showsName = showsName
        self.showsMicrophoneBadge = showsMicrophoneBadge
        self.showsConnectionBadge = showsConnectionBadge
        self.speakingHighlight = speakingHighlight
    }
}

/// One participant's self-updating render surface.
///
/// Delivered for remote participants through `MeetingSession.onRemoteCanvasJoined`; the app
/// stores the value and lays it out freely (frame, position, gestures). The canvas observes
/// the session, so video, mute state, speaking and quality follow the meeting without the
/// app diffing snapshots. Camera state is intentionally not drawn: a closed camera shows the
/// avatar, matching the reference clients.
public struct ParticipantCanvas: View, Identifiable {
    @ObservedObject private var session: MeetingSession
    public let id: ParticipantID
    /// The display name at delivery time. Renames after that are reflected inside the canvas;
    /// use `tile()` for the live value.
    public let displayName: String
    private var style: ParticipantCanvasStyle

    init(session: MeetingSession, participantID: ParticipantID, style: ParticipantCanvasStyle) {
        self._session = ObservedObject(wrappedValue: session)
        self.id = participantID
        self.displayName = session.tiles.first { $0.id == participantID }?.displayName ?? ""
        self.style = style
    }

    /// True for `MeetingSession.localCanvas(style:)`.
    public var isLocal: Bool { id == MeetingSession.Tile.localID }

    /// The live row behind this canvas, including the current display name and avatar.
    public func tile() -> MeetingSession.Tile? {
        session.tiles.first { $0.id == id }
    }

    /// A copy with its own appearance. The session default is untouched.
    public func style(_ style: ParticipantCanvasStyle) -> ParticipantCanvas {
        var copy = self
        copy.style = style
        return copy
    }

    public var body: some View {
        ParticipantCanvasContent(
            participant: session.tiles.first { $0.id == id }.map(CanvasParticipant.init(tile:)),
            isLocal: isLocal,
            style: style,
            frames: { session.frames(for: $0) }
        )
    }
}

/// The values a canvas draws. `ParticipantCanvas` rebuilds it from the session on every
/// render; a non-SwiftUI host (the ObjC façade) can keep its own copy and update it.
public struct CanvasParticipant: Identifiable, Equatable, Sendable {
    public let id: ParticipantID
    public let displayName: String
    public let avatarURL: String?
    public let videoTrackID: TrackID?
    public let audioMuted: Bool
    public let audioLevel: Double
    public let isSpeaking: Bool
    public let raisedHand: Bool
    public let connectionQualityLevel: Int?

    public init(
        id: ParticipantID,
        displayName: String,
        avatarURL: String?,
        videoTrackID: TrackID?,
        audioMuted: Bool,
        audioLevel: Double,
        isSpeaking: Bool,
        raisedHand: Bool,
        connectionQualityLevel: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.videoTrackID = videoTrackID
        self.audioMuted = audioMuted
        self.audioLevel = audioLevel
        self.isSpeaking = isSpeaking
        self.raisedHand = raisedHand
        self.connectionQualityLevel = connectionQualityLevel
    }
}

extension CanvasParticipant {
    init(tile: MeetingSession.Tile) {
        self.init(
            id: tile.id,
            displayName: tile.displayName,
            avatarURL: tile.avatarURL,
            videoTrackID: tile.videoTrackID,
            audioMuted: tile.audioMuted,
            audioLevel: tile.audioLevel,
            isSpeaking: tile.isSpeaking,
            raisedHand: tile.raisedHand,
            connectionQualityLevel: tile.connectionQualityLevel
        )
    }
}

/// The rendering shared by `ParticipantCanvas` and the ObjC bridge. It takes a plain value
/// plus a frame-stream factory instead of a session, so it can be hosted anywhere.
public struct ParticipantCanvasContent: View {
    private let participant: CanvasParticipant?
    private let isLocal: Bool
    private var style: ParticipantCanvasStyle
    private let frames: (TrackID) -> AsyncStream<VideoPixelFrame>

    public init(
        participant: CanvasParticipant?,
        isLocal: Bool,
        style: ParticipantCanvasStyle = ParticipantCanvasStyle(),
        frames: @escaping (TrackID) -> AsyncStream<VideoPixelFrame>
    ) {
        self.participant = participant
        self.isLocal = isLocal
        self.style = style
        self.frames = frames
    }

    public var body: some View {
        let row = participant
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)

        ZStack {
            if let trackID = row?.videoTrackID {
                VideoSurface(
                    frames: frames(trackID),
                    mirrored: isLocal,
                    fillMode: style.videoFillMode
                )
                // A camera↔screen-share switch means a different stream; restarting the
                // player is the only way the representable picks it up.
                .id(trackID)
            } else {
                placeholder(row)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            if style.showsConnectionBadge, let level = row?.connectionQualityLevel {
                ConnectionQualityBadge(level: level)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            bottomBar(row)
        }
        .overlay(alignment: .bottomTrailing) {
            if row?.isSpeaking == true {
                SpeakingPulse()
                    .padding(10)
            }
        }
        .overlay {
            shape
                .strokeBorder(Color.green, lineWidth: 3)
                .opacity(showsSpeakingRing(row) ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: row?.isSpeaking)
                .allowsHitTesting(false)
        }
        .contentShape(shape)
    }

    private func showsSpeakingRing(_ row: CanvasParticipant?) -> Bool {
        style.speakingHighlight == .ring && row?.isSpeaking == true
    }

    private func placeholder(_ row: CanvasParticipant?) -> some View {
        ZStack {
            Color(white: 0.12)
            ParticipantAvatar(name: row?.displayName ?? "", url: row?.avatarURL, size: style.avatarSize)
        }
    }

    private func bottomBar(_ row: CanvasParticipant?) -> some View {
        HStack(spacing: 6) {
            if row?.raisedHand == true {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.yellow)
            }
            if style.showsMicrophoneBadge {
                if row?.audioMuted ?? true {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.red)
                } else {
                    AudioLevelMeter(level: row?.audioLevel ?? 0)
                }
            }
            if style.showsName {
                Text(row?.displayName ?? "")
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(10)
    }
}

/// Three bars whose fill and colour follow lib-jitsi-meet's 0...100 quality level, using the
/// same thresholds as the reference client (≥30 good, 10...29 fair, <10 poor).
public struct ConnectionQualityBadge: View {
    public let level: Int?

    public init(level: Int?) {
        self.level = level
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                let filled = index < filledBars
                RoundedRectangle(cornerRadius: 1)
                    .fill(filled ? color : Color.white.opacity(0.35))
                    .frame(width: 3, height: 4 + CGFloat(index) * 3)
            }
        }
        .padding(4)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .accessibilityLabel(Text(label))
    }

    private var filledBars: Int {
        guard let level else { return 0 }
        if level >= 30 { return 3 }
        if level >= 10 { return 2 }
        return 1
    }

    private var color: Color {
        guard let level else { return .gray }
        if level >= 30 { return .green }
        if level >= 10 { return .yellow }
        return .red
    }

    /// Stable text form of the same thresholds, for logs and accessibility.
    public var label: String {
        guard let level else { return "unknown" }
        if level >= 30 { return "good" }
        if level >= 10 { return "fair" }
        return "poor"
    }
}

/// Blinking speaker, so "someone is talking" also reads when the ring is hidden.
private struct SpeakingPulse: View {
    @State private var visible = false

    var body: some View {
        Image(systemName: "speaker.wave.2.fill")
            .font(.footnote)
            .foregroundStyle(.green)
            .shadow(radius: 2)
            .opacity(visible ? 1 : 0.25)
            .animation(
                .easeInOut(duration: 0.6).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible = true }
            .accessibilityLabel(Text("Speaking"))
    }
}
