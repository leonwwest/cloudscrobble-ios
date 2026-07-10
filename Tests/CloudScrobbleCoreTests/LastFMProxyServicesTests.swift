import Foundation
import XCTest
@testable import CloudScrobbleCore

final class LastFMProxyServicesTests: XCTestCase {
    override func tearDown() {
        ProxyStubURLProtocol.reset()
        super.tearDown()
    }

    func testGeneric401KeepsQueuedScrobbleAndThrows() async throws {
        try await assertGenericHTTPFailureKeepsQueue(statusCode: 401)
    }

    func testGeneric429KeepsQueuedScrobbleAndThrows() async throws {
        try await assertGenericHTTPFailureKeepsQueue(statusCode: 429)
    }

    func testGeneric5xxKeepsQueuedScrobbleAndThrows() async throws {
        try await assertGenericHTTPFailureKeepsQueue(statusCode: 503)
    }

    private func assertGenericHTTPFailureKeepsQueue(statusCode: Int) async throws {
        let pending = PendingScrobble(
            meta: LastFMTrackMeta(artist: "Artist", track: "Track"),
            timestamp: 1_700_000_000
        )
        let store = InMemoryScrobbleQueueStore(queue: [pending])
        let auth = FixedLastFMAuthService()
        ProxyStubURLProtocol.setHandler { request in
            XCTAssertEqual(request.httpMethod, "POST")
            return (statusCode, Data(#"{"error":"broker_failure","message":"try later"}"#.utf8))
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProxyStubURLProtocol.self]
        let client = HTTPClient(session: URLSession(configuration: configuration))
        let service = LastFMProxyScrobbleService(
            baseURL: URL(string: "https://broker.example")!,
            authService: auth,
            queueStore: store,
            httpClient: client
        )

        do {
            try await service.flushPendingScrobbles()
            XCTFail("Expected generic HTTP failure")
        } catch CloudScrobbleError.httpStatus(let actualStatus, _) {
            XCTAssertEqual(actualStatus, statusCode)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let pendingCount = await service.pendingScrobbleCount()
        XCTAssertEqual(pendingCount, 1)
        XCTAssertEqual(try store.load(), [pending])
    }
}

private actor FixedLastFMAuthService: LastFMAuthenticating {
    private var session = LastFMSession(name: "user", key: "session", subscriber: 0)

    func authenticate(username: String, password: String) async throws -> LastFMSession { session }
    func cachedSession() async -> LastFMSession? { session }
    func setCachedSession(_ session: LastFMSession) async throws { self.session = session }
    func clearSession() async throws {}
}

private final class InMemoryScrobbleQueueStore: ScrobbleQueueStoreing, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [PendingScrobble]

    init(queue: [PendingScrobble]) {
        self.queue = queue
    }

    func load() throws -> [PendingScrobble] {
        lock.withLock { queue }
    }

    func save(_ queue: [PendingScrobble]) throws {
        lock.withLock { self.queue = queue }
    }

    func clear() throws {
        lock.withLock { queue = [] }
    }
}

private final class ProxyStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> (Int, Data)) {
        lock.withLock { self.handler = handler }
    }

    static func reset() {
        lock.withLock { handler = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
