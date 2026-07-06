import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum NetworkURLPolicy {
    /// Returns true if `url` points at a host on the local network
    /// (loopback, link-local, ULA, RFC1918, `.local`, or `localhost`).
    ///
    /// IPv6 ULA (fc00::/7) and link-local (fe80::/10) are checked by parsing the
    /// 16-byte address rather than naive prefix matching, so hostnames like
    /// `fc-mobile.com` are not misclassified as local.
    public static func isLocalNetworkURL(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }

        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        if host == "::1" {
            return true
        }

        if host.contains(":") {
            return isLocalIPv6(host)
        }

        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }

        return false
    }

    private static func isLocalIPv6(_ host: String) -> Bool {
        #if canImport(Darwin)
        var addr = in6_addr()
        guard inet_pton(AF_INET6, host, &addr) == 1 else {
            return false
        }
        let bytes = withUnsafeBytes(of: addr) { Array($0) }
        // fc00::/7 (Unique Local Addresses): first byte's top 7 bits are 1111110.
        if (bytes[0] & 0xFE) == 0xFC {
            return true
        }
        // fe80::/10 (Link-Local): first byte 0xFE, second byte top two bits 10.
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 {
            return true
        }
        #endif
        return false
    }
}
