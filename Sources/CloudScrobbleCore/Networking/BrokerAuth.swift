import Foundation

public enum BrokerAuth {
    public static let headerName = "X-API-Key"

    public static func apply(_ appAPIKey: String?, to request: inout URLRequest) {
        guard let appAPIKey, !appAPIKey.isEmpty else {
            return
        }
        request.setValue(appAPIKey, forHTTPHeaderField: headerName)
    }
}
