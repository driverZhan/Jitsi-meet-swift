import JitsiCore
import SwiftUI

/// The tile layout: one stage plus a filmstrip, built entirely from `MeetingSession` values.
public struct VideoGrid: View {
    private let model: MeetingSession
    private let filmstripHeight: CGFloat

    public init(model: MeetingSession, filmstripHeight: CGFloat = 108) {
        self.model = model
        self.filmstripHeight = filmstripHeight
    }

    private var stage: MeetingSession.Tile? {
        model.tiles.first(where: { $0.isDominantSpeaker && $0.videoTrackID != nil })
            ?? model.tiles.first(where: { $0.videoTrackID != nil })
            ?? model.tiles.first
    }

    private var strip: [MeetingSession.Tile] {
        guard let stage else { return [] }
        return model.tiles.filter { $0.id != stage.id }
    }

    public var body: some View {
        VStack(spacing: 8) {
            stageTile
            if !strip.isEmpty {
                filmstrip
            }
        }
        .padding(8)
    }

    private var stageTile: some View {
        Group {
            if let stage {
                ZStack(alignment: .bottomLeading) {
                    TrackVideo(model: model, trackID: stage.videoTrackID, mirrored: stage.isLocal)
                    overlays(for: stage)
                        .padding(10)
                }
                .overlay { speakingRing(for: stage, cornerRadius: 12) }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                WaitingRoom()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filmstrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(strip) { tile in
                    ZStack(alignment: .bottomLeading) {
                        TrackVideo(model: model, trackID: tile.videoTrackID, mirrored: tile.isLocal)
                        overlays(for: tile)
                            .padding(6)
                    }
                    .overlay { speakingRing(for: tile, cornerRadius: 8) }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: filmstripHeight * 16 / 9, height: filmstripHeight)
                }
            }
        }
        .frame(height: filmstripHeight)
    }

    /// The green outline jitsi-meet puts around the active speaker. The level is already
    /// smoothed by the lib's 200 ms audio level events, so a simple threshold is enough.
    @ViewBuilder
    private func speakingRing(for tile: MeetingSession.Tile, cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.green, lineWidth: 3)
            .opacity(tile.isSpeaking ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: tile.isSpeaking)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func overlays(for tile: MeetingSession.Tile) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if tile.raisedHand {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.yellow)
            }
            HStack(spacing: 6) {
                if tile.audioMuted {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.red)
                } else {
                    AudioLevelMeter(level: tile.audioLevel)
                }
                if tile.videoMuted {
                    Image(systemName: "video.slash.fill")
                        .foregroundStyle(.red)
                }
                Text(tile.displayName)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if let quality = tile.connectionQuality {
                    Text(quality)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(radius: 2)
    }
}

/// Four segments filled by mic level, so a viewer sees who is audible even without the
/// speaking ring (e.g. in a crowded filmstrip). Public so a custom layout can reuse the
/// same affordance with `tile.audioLevel`.
public struct AudioLevelMeter: View {
    public let level: Double

    public init(level: Double) {
        self.level = level
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { index in
                let threshold = Double(index + 1) / 4
                RoundedRectangle(cornerRadius: 1)
                    .fill(level >= threshold ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 2.5, height: 4 + CGFloat(index) * 2)
            }
        }
        .animation(.linear(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

private struct WaitingRoom: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.fill")
                .font(.system(size: 40))
            Text("Waiting for others to join")
                .font(.subheadline)
        }
        .foregroundStyle(.white.opacity(0.75))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
