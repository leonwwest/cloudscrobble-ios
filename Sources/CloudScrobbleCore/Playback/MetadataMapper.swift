import Foundation

public enum MetadataMapper {
    public static func mapLastFM(track: SCTrack) -> LastFMTrackMeta {
        if let artist = nonEmpty(track.publisherMetadata?.artist),
           let releaseTitle = nonEmpty(track.publisherMetadata?.releaseTitle) {
            return LastFMTrackMeta(artist: artist, track: sanitize(title: releaseTitle))
        }

        let title = sanitize(title: track.title)
        if let pair = splitArtistTitle(title) {
            return LastFMTrackMeta(artist: pair.artist, track: pair.track)
        }

        return LastFMTrackMeta(artist: track.user.username, track: title)
    }

    private static func splitArtistTitle(_ title: String) -> (artist: String, track: String)? {
        let separators = [" - ", " – ", " — "]

        for separator in separators {
            let parts = title.components(separatedBy: separator)
            if parts.count == 2,
               let artist = nonEmpty(parts[0]),
               let track = nonEmpty(parts[1]) {
                return (artist, track)
            }
        }

        return nil
    }

    private static func sanitize(title: String) -> String {
        var cleaned = title
        let patterns = [
            #"\[.*?free download.*?\]"#,
            #"\(.*?free download.*?\)"#,
            #"\[.*?out now.*?\]"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
