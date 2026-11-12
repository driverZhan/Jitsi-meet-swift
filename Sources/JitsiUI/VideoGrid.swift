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
                    .frame(width: filmstripHeight * 16 / 9, height: filmstripHeight)
                }
            }
        }
        .frame(height: filmstripHeight)
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
