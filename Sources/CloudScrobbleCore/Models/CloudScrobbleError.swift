import Foundation

public enum CloudScrobbleError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case invalidResponse
    case httpStatus(Int, Data?)
    case oauthCallbackMissingCode
    case oauthStateMismatch
    case missingToken
    case unsupportedStream
    case noQueue
    case noCurrentTrack
    case lastFMError(code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .invalidResponse:
            return "Server response could not be decoded."
        case .httpStatus(let code, _):
            return "Request failed with HTTP \(code)."
        case .oauthCallbackMissingCode:
            return "OAuth callback did not include an authorization code."
        case .oauthStateMismatch:
            return "OAuth state mismatch detected."
        case .missingToken:
            return "No valid access token available."
        case .unsupportedStream:
            return "No supported HLS stream available for this track."
        case .noQueue:
            return "No active queue loaded."
        case .noCurrentTrack:
            return "No current track selected."
        case .lastFMError(let code, let message):
            return "Last.fm error \(code): \(message)"
        }
    }
}
