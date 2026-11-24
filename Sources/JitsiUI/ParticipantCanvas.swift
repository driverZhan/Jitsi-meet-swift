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

/// Where an overlay (avatar or caption) sits inside the canvas rectangle.
public enum CanvasOverlayPlacement: String, Sendable, CaseIterable {
    case center
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var alignment: Alignment {
        switch self {
        case .center: return .center
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

/// Appearance of a `ParticipantCanvas`. The session-level default is
/// `MeetingSession.canvasStyle`; a single canvas can override it with
/// `ParticipantCanvas.style(_:)`.
public struct ParticipantCanvasStyle: Sendable {
    public var videoFillMode: VideoFillMode
    public var cornerRadius: CGFloat
    /// Avatar diameter while the camera is off.
    public var avatarSize: CGFloat
    /// The avatar drawn while the camera is off (or before the first frame).
    public var showsAvatar: Bool
    /// Where the avatar sits while the camera is off.
    public var avatarPlacement: CanvasOverlayPlacement
    public var showsName: Bool
    /// Where the caption row (microphone meter + name) sits.
    public var namePlacement: CanvasOverlayPlacement
    /// Name text size, in points.
    public var nameFontSize: CGFloat
    /// Red `mic.slash` while muted, the level meter while open.
    public var showsMicrophoneBadge: Bool
    /// The moving level meter left of the name. Turn it off to keep the caption still while
    /// the participant talks; the mute icon stays under `showsMicrophoneBadge`.
    public var showsAudioLevel: Bool
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
        speakingHighlight: SpeakingHighlight = .ring,
        avatarPlacement: CanvasOverlayPlacement = .center,
        namePlacement: CanvasOverlayPlacement = .bottomLeading,
        nameFontSize: CGFloat = 13,
        showsAvatar: Bool = true,
        showsAudioLevel: Bool = true
    ) {
        self.videoFillMode = videoFillMode
        self.cornerRadius = cornerRadius
        self.avatarSize = avatarSize
        self.showsAvatar = showsAvatar
        self.avatarPlacement = avatarPlacement
        self.showsName = showsName
        self.namePlacement = namePlacement
        self.nameFontSize = nameFontSize
        self.showsMicrophoneBadge = showsMicrophoneBadge
        self.showsAudioLevel = showsAudioLevel
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
    /// Overrides the default "mirror when local". Pass false for a rear-camera self-view.
    private let mirrored: Bool
    private var style: ParticipantCanvasStyle
    private let frames: (TrackID) -> AsyncStream<VideoPixelFrame>
    /// Stream currently on screen, keyed by track so a camera↔share switch rebuilds it.
    @State private var surface: SurfaceStream?

    private struct SurfaceStream {
        let trackID: TrackID
        let frames: AsyncStream<VideoPixelFrame>
    }

    public init(
        participant: CanvasParticipant?,
        isLocal: Bool,
        mirrored: Bool? = nil,
        style: ParticipantCanvasStyle = ParticipantCanvasStyle(),
        frames: @escaping (TrackID) -> AsyncStream<VideoPixelFrame>
    ) {
        self.participant = participant
        self.isLocal = isLocal
        self.mirrored = mirrored ?? isLocal
        self.style = style
        self.frames = frames
    }

    public var body: some View {
        let row = participant
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)

        ZStack {
            if let cached = surface, cached.trackID == row?.videoTrackID {
                VideoSurface(
                    frames: cached.frames,
                    identity: AnyHashable(cached.trackID),
                    mirrored: mirrored,
                    fillMode: style.videoFillMode
                )
            } else if row?.videoTrackID == nil {
                placeholder(row)
            } else {
                // One pass while the new stream is created below; the old picture must not
                // linger, so a blank surface is shown instead.
                Color(white: 0.12)
            }
        }
        // A camera↔screen-share switch means a different stream. Build it once per track:
        // a fresh `AsyncStream` on every body pass would leave its sink in the backend.
        .task(id: row?.videoTrackID) {
            guard let trackID = row?.videoTrackID else {
                surface = nil
                return
            }
            guard surface?.trackID != trackID else { return }
            surface = SurfaceStream(trackID: trackID, frames: frames(trackID))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            if style.showsConnectionBadge, let level = row?.connectionQualityLevel {
                ConnectionQualityBadge(level: level)
                    .padding(8)
            }
        }
        .overlay {
            caption(row)
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
            if style.showsAvatar {
                ParticipantAvatar(name: row?.displayName ?? "", url: row?.avatarURL, size: style.avatarSize)
                    .padding(style.avatarPlacement == .center ? 0 : 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.avatarPlacement.alignment)
            }
        }
    }

    /// Raised hand, microphone state and name. The whole row moves together so the name
    /// never lands on top of its own meter.
    private func caption(_ row: CanvasParticipant?) -> some View {
        HStack(spacing: 6) {
            if row?.raisedHand == true {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.yellow)
            }
            if style.showsMicrophoneBadge {
                if row?.audioMuted ?? true {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.red)
                } else if style.showsAudioLevel {
                    AudioLevelMeter(level: row?.audioLevel ?? 0)
                }
            }
            if style.showsName {
                Text(row?.displayName ?? "")
                    .font(.system(size: style.nameFontSize, weight: .medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: style.namePlacement.alignment)
        .allowsHitTesting(false)
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
