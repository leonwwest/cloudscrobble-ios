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
        case .httpStatus(let code, let data):
            if code == 401 {
                return "SoundCloud session expired. Reconnect SoundCloud if this keeps happening."
            }
            if let details = Self.httpErrorDetails(from: data) {
                return "Request failed with HTTP \(code): \(details)"
            }
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
            return Self.lastFMErrorDescription(code: code, message: message)
        }
    }

    private static func lastFMErrorDescription(code: Int, message: String) -> String {
        switch code {
        case 4:
            return "Last.fm login failed: username or password is wrong."
        case 9:
            return "Last.fm session expired. Connect Last.fm again."
        case 11:
            return "Last.fm is offline right now. Scrobbles stay queued."
        case 16:
            return "Last.fm is temporarily unavailable. Scrobbles stay queued."
        case 26:
            return "Last.fm rejected this API key."
        case 29:
            return "Last.fm rate limit reached. Scrobbles stay queued."
        default:
            return "Last.fm error \(code): \(message)"
        }
    }

    private static func httpErrorDetails(from data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorDescription = payload["error_description"] as? String, !errorDescription.isEmpty {
                return errorDescription
            }
            if let message = payload["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = payload["error"] as? String, !error.isEmpty {
                return error
            }
        }

        return nil
    }
}
