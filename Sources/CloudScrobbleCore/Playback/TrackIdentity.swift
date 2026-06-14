import Foundation

public enum TrackIdentity {
    public static func displayMetadata(for track: SCTrack) -> LastFMTrackMeta {
        MetadataMapper.mapLastFM(track: track)
    }

    public static func canonicalKey(for track: SCTrack) -> String {
        let metadata = displayMetadata(for: track)
        let artist = normalizedComponent(metadata.artist)
        let title = normalizedComponent(metadata.track)

        if !artist.isEmpty, !title.isEmpty {
            return "meta:\(artist):\(title)"
        }

        if let permalink = track.permalinkURL?.absoluteString, !permalink.isEmpty {
            return "url:\(permalink.lowercased())"
        }

        return "urn:\(track.urn)"
    }

    public static func uniqueTracks(_ tracks: [SCTrack]) -> [SCTrack] {
        var seen = Set<String>()
        return tracks.filter { track in
            seen.insert(canonicalKey(for: track)).inserted
        }
    }

    private static func normalizedComponent(_ value: String) -> String {
        let folded = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()

        var cleaned = folded
        let patterns = [
            #"(?i)\b(feat\.?|ft\.?|featuring)\b"#,
            #"(?i)\b(official\s+audio|official\s+video|visualizer|lyrics?)\b"#,
            #"(?i)\b(free\s+download|out\s+now)\b"#,
            #"[^\p{L}\p{N}]+"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        return cleaned
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
