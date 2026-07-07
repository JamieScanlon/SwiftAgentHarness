//
//  SSRF blocklist for resolved and literal IP addresses on blob URL fetch.
//

import Foundation

enum SessionBlockedIPAddress {
    static func isBlocked(host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".localhost") || h == "0.0.0.0" { return true }
        if let literal = parseIPv4(h) {
            return isBlockedIPv4(literal)
        }
        if let literal = parseIPv6(h) {
            return isBlockedIPv6(literal)
        }
        if h.hasPrefix("127.") || h == "::1" || h.hasPrefix("fe80:") || h.hasPrefix("fc") || h.hasPrefix("fd") {
            return true
        }
        if h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") || h.hasPrefix("100.64.") {
            return true
        }
        if h.hasPrefix("172.") {
            let parts = h.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16 ... 31).contains(second) {
                return true
            }
        }
        return false
    }

    static func isBlockedSockaddr(_ data: Data) -> Bool {
        guard data.count >= MemoryLayout<sockaddr>.size else { return true }
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else { return true }
            switch Int32(base.pointee.sa_family) {
            case AF_INET:
                guard data.count >= MemoryLayout<sockaddr_in>.size else { return true }
                let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee
                let bytes = withUnsafeBytes(of: sin.sin_addr) { Array($0.prefix(4)) }
                return isBlockedIPv4(bytes)
            case AF_INET6:
                guard data.count >= MemoryLayout<sockaddr_in6>.size else { return true }
                let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee
                let bytes = withUnsafeBytes(of: sin6.sin6_addr) { Array($0) }
                return isBlockedIPv6(bytes)
            default:
                return true
            }
        }
    }

    static func isBlockedIPv4(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return true }
        if bytes[0] == 0 { return true }
        if bytes[0] == 127 { return true }
        if bytes[0] == 10 { return true }
        if bytes[0] == 192, bytes[1] == 168 { return true }
        if bytes[0] == 169, bytes[1] == 254 { return true }
        if bytes[0] == 100, (64 ... 127).contains(bytes[1]) { return true }
        if bytes[0] == 172, (16 ... 31).contains(bytes[1]) { return true }
        return false
    }

    static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if isIPv4MappedAddress(bytes) {
            return isBlockedIPv4(Array(bytes[12 ..< 16]))
        }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if bytes[0 ..< 8].allSatisfy({ $0 == 0 }), bytes[15] == 1 { return true }
        if bytes[0] == 0xfe, (bytes[1] & 0xc0) == 0x80 { return true }
        if bytes[0] == 0xfc || bytes[0] == 0xfd { return true }
        return false
    }

    private static func parseIPv4(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var bytes: [UInt8] = []
        for part in parts {
            guard let n = Int(part), (0 ... 255).contains(n) else { return nil }
            bytes.append(UInt8(n))
        }
        return bytes
    }

    private static func parseIPv6(_ host: String) -> [UInt8]? {
        var h = host
        if h.hasPrefix("[") && h.hasSuffix("]") {
            h = String(h.dropFirst().dropLast())
        }
        if let mapped = parseIPv4MappedIPv6Text(h) {
            return mapped
        }
        guard h.contains(":") else { return nil }
        var groups = h.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if groups.count > 8 { return nil }
        if let emptyIndex = groups.firstIndex(where: { $0.isEmpty }) {
            let tail = groups.suffix(from: groups.index(after: emptyIndex)).filter { !$0.isEmpty }
            let headCount = groups.prefix(upTo: emptyIndex).filter { !$0.isEmpty }.count
            let missing = 8 - headCount - tail.count
            guard missing >= 0 else { return nil }
            groups = Array(groups.prefix(upTo: emptyIndex).filter { !$0.isEmpty })
            groups.append(contentsOf: Array(repeating: "0", count: missing))
            groups.append(contentsOf: tail)
        }
        guard groups.count == 8 else { return nil }
        var bytes: [UInt8] = []
        for group in groups {
            guard let value = UInt16(group, radix: 16), value <= 0xffff else { return nil }
            bytes.append(UInt8(value >> 8))
            bytes.append(UInt8(value & 0xff))
        }
        return bytes
    }

    /// Textual IPv4-mapped IPv6 such as `::ffff:10.0.0.1` → 16-byte form for blocklist checks.
    private static func parseIPv4MappedIPv6Text(_ host: String) -> [UInt8]? {
        let lower = host.lowercased()
        if lower.hasPrefix("::ffff:"), let v4 = parseIPv4(String(lower.dropFirst("::ffff:".count))) {
            return ipv4MappedIPv6Bytes(embeddedIPv4: v4)
        }
        guard lower.contains(":"), lower.contains(".") else { return nil }
        let groups = lower.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard groups.count >= 2, groups.contains(where: { $0 == "ffff" }) else { return nil }
        guard let last = groups.last, last.contains("."), let v4 = parseIPv4(last) else { return nil }
        return ipv4MappedIPv6Bytes(embeddedIPv4: v4)
    }

    private static func ipv4MappedIPv6Bytes(embeddedIPv4 v4: [UInt8]) -> [UInt8]? {
        guard v4.count == 4 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xff
        bytes[11] = 0xff
        bytes[12 ..< 16] = v4[0 ..< 4]
        return bytes
    }

    private static func isIPv4MappedAddress(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        return bytes[0 ..< 10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff
    }
}
