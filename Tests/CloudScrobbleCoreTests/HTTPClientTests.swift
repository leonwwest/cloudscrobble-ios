import Foundation
import XCTest
@testable import CloudScrobbleCore

final class HTTPClientTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRetriesTransientStatusForGET() async throws {
        let counter = LockedCounter()
        StubURLProtocol.setHandler { request in
            let attempt = counter.increment()
            return .response(status: attempt == 1 ? 503 : 200, headers: [:], data: Data())
        }

        let client = makeClient()
        var request = URLRequest(url: URL(string: "https://example.com/resource")!)
        request.httpMethod = "GET"
        _ = try await client.send(
            request,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0)
        )

        XCTAssertEqual(counter.value, 2)
    }

    func testDoesNotRetryPOSTWithoutIdempotencyKey() async {
        let counter = LockedCounter()
        StubURLProtocol.setHandler { _ in
            _ = counter.increment()
            return .response(status: 503, headers: [:], data: Data())
        }

        var request = URLRequest(url: URL(string: "https://example.com/scrobble")!)
        request.httpMethod = "POST"

        do {
            _ = try await makeClient().send(
                request,
                retryPolicy: RetryPolicy(maxAttempts: 3, baseDelay: 0, maxDelay: 0)
            )
            XCTFail("Expected HTTP error")
        } catch CloudScrobbleError.httpStatus(let status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(counter.value, 1)
    }

    func testRetriesPOSTOnlyWithExplicitIdempotencyKey() async throws {
        let counter = LockedCounter()
        StubURLProtocol.setHandler { _ in
            let attempt = counter.increment()
            return .response(status: attempt == 1 ? 503 : 200, headers: [:], data: Data())
        }

        var request = URLRequest(url: URL(string: "https://example.com/idempotent-operation")!)
        request.httpMethod = "POST"
        request.setValue("operation-123", forHTTPHeaderField: "Idempotency-Key")
        _ = try await makeClient().send(
            request,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0)
        )

        XCTAssertEqual(counter.value, 2)
    }

    func testRetriesTransientTransportFailureForGET() async throws {
        let counter = LockedCounter()
        StubURLProtocol.setHandler { _ in
            let attempt = counter.increment()
            return attempt == 1
                ? .failure(URLError(.networkConnectionLost))
                : .response(status: 200, headers: [:], data: Data())
        }

        var request = URLRequest(url: URL(string: "https://example.com/resource")!)
        request.httpMethod = "GET"
        _ = try await makeClient().send(
            request,
            retryPolicy: RetryPolicy(maxAttempts: 2, baseDelay: 0, maxDelay: 0)
        )

        XCTAssertEqual(counter.value, 2)
    }

    func testAppliesShorterRequestDeadline() async throws {
        let observedTimeout = LockedValue<TimeInterval?>(nil)
        StubURLProtocol.setHandler { request in
            observedTimeout.set(request.timeoutInterval)
            return .response(status: 200, headers: [:], data: Data())
        }

        let request = URLRequest(url: URL(string: "https://example.com/resource")!)
        _ = try await makeClient(requestTimeout: 8).send(request)

        XCTAssertEqual(try XCTUnwrap(observedTimeout.value), 8, accuracy: 0.001)
    }

    private func makeClient(requestTimeout: TimeInterval = 20) -> HTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return HTTPClient(session: URLSession(configuration: configuration), requestTimeout: requestTimeout)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func set(_ value: Value) {
        lock.withLock { storage = value }
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(status: Int, headers: [String: String], data: Data)
        case failure(Error)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: ((URLRequest) throws -> Outcome)?

    static func setHandler(_ handler: @escaping (URLRequest) throws -> Outcome) {
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
            switch try handler(request) {
            case .response(let status, let headers, let data):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(let error):
                client?.urlProtocol(self, didFailWithError: error)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
