import XCTest
@testable import CloudScrobbleCore

final class NetworkURLPolicyTests: XCTestCase {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testLoopbackAndLocalhost() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://localhost:8080")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://127.0.0.1:8080")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://127.255.255.255")))
    }

    func testDotLocal() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://mybroker.local")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://sub.host.local")))
    }

    func testRFC1918Ranges() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://10.0.0.1")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://192.168.1.1")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://172.16.0.1")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://172.31.255.255")))
    }

    func testNonLocalRFC1918Boundaries() {
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://172.15.0.1")))
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://172.32.0.1")))
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://11.0.0.1")))
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://192.169.0.1")))
    }

    func testPublicHostsAreNotLocal() {
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("https://broker.example")))
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("https://example.com")))
    }

    func testFCPrefixedHostnameIsNotMisclassifiedAsULA() {
        // Regression: the old hasPrefix("fc") check wrongly flagged this as local.
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("https://fc-mobile.com")))
    }

    func testIPv6Loopback() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://[::1]:8080")))
    }

    func testIPv6ULAInRange() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://[fc00::1]:8080")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://[fd12:3456:789a::1]:8080")))
    }

    func testIPv6LinkLocal() {
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://[fe80::1]:8080")))
        XCTAssertTrue(NetworkURLPolicy.isLocalNetworkURL(url("http://[febf::1]:8080")))
    }

    func testIPv6GlobalIsNotLocal() {
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://[2606:4700::1]:8080")))
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("http://[2001:db8::1]:8080")))
    }

    func testNoHostReturnsFalse() {
        XCTAssertFalse(NetworkURLPolicy.isLocalNetworkURL(url("file:///path")))
    }
}
