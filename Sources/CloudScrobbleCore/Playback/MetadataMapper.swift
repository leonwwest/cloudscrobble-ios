import Foundation

public enum MetadataMapper {
    public static func mapLastFM(track: SCTrack) -> LastFMTrackMeta {
        let publisherArtist = nonEmpty(track.publisherMetadata?.artist)
        if let artist = publisherArtist,
           let releaseTitle = nonEmpty(track.publisherMetadata?.releaseTitle) {
            return LastFMTrackMeta(artist: artist, track: sanitize(title: releaseTitle))
        }

        let title = sanitize(title: track.title)
        if let pair = splitArtistTitle(title) {
            return LastFMTrackMeta(artist: pair.artist, track: pair.track)
        }

        if let publisherArtist {
            return LastFMTrackMeta(artist: publisherArtist, track: title)
        }

        return LastFMTrackMeta(artist: track.user.username, track: title)
    }

    private static func splitArtistTitle(_ title: String) -> (artist: String, track: String)? {
        let separators = [" - ", " – ", " — "]

        for separator in separators {
            guard let range = title.range(of: separator) else { continue }

            let artistPart = String(title[..<range.lowerBound])
            let trackPart = String(title[range.upperBound...])

            if let artist = nonEmpty(artistPart),
               let track = nonEmpty(trackPart) {
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
