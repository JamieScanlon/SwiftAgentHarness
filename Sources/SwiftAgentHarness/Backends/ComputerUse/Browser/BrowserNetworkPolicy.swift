import Foundation

/// An IP address as the network policy classifies it.
public enum BrowserNetworkAddress: Sendable, Hashable, CustomStringConvertible {
    case v4([UInt8])
    case v6([UInt8])

    /// Parses dotted IPv4 (including the shorthand, octal, and hex forms `inet_aton` accepts, which some URL parsers
    /// pass through) and IPv6, with or without brackets. A zone id (`fe80::1%en0`) is dropped.
    public init?(_ raw: String) {
        var text = raw
        if text.hasPrefix("["), text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        if let zone = text.firstIndex(of: "%") { text = String(text[..<zone]) }
        guard !text.isEmpty else { return nil }
        if text.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, text, &address) == 1 else { return nil }
            self = .v6(withUnsafeBytes(of: address) { Array($0) })
        } else {
            var address = in_addr()
            guard text.allSatisfy({ $0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X" }),
                  inet_aton(text, &address) != 0 else { return nil }
            self = .v4(withUnsafeBytes(of: address) { Array($0) })
        }
    }

    public var description: String {
        switch self {
        case .v4(let bytes):
            return bytes.map(String.init).joined(separator: ".")
        case .v6(let bytes):
            var address = in6_addr()
            withUnsafeMutableBytes(of: &address) { $0.copyBytes(from: bytes) }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(buffer.count)) != nil else { return "?" }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    /// Why the address is not on the public internet, or `nil` when it is. IPv6 forms that embed an IPv4 address
    /// (mapped, compatible, NAT64, 6to4) are judged by the address they embed.
    public var nonPublicReason: String? {
        switch self {
        case .v4(let b):
            guard b.count == 4 else { return "malformed address" }
            switch (b[0], b[1], b[2]) {
            case (0, _, _): return "unspecified address"
            case (10, _, _): return "private address"
            case (100, 64...127, _): return "shared address space"
            case (127, _, _): return "loopback address"
            case (169, 254, _): return "link-local address"
            case (172, 16...31, _): return "private address"
            case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113), (192, 88, 99): return "reserved address"
            case (192, 168, _): return "private address"
            case (198, 18...19, _): return "benchmarking address"
            case (224...239, _, _): return "multicast address"
            case (240...255, _, _): return "reserved address"
            default: return nil
            }
        case .v6(let b):
            guard b.count == 16 else { return "malformed address" }
            let embedded = BrowserNetworkAddress.v4(Array(b[12..<16]))
            if b[0..<15].allSatisfy({ $0 == 0 }) { return b[15] == 1 ? "loopback address" : "unspecified address" }
            if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return embedded.nonPublicReason }
            if b[0..<12].allSatisfy({ $0 == 0 }) { return embedded.nonPublicReason ?? "deprecated IPv4-compatible address" }
            if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b {
                if b[4..<12].allSatisfy({ $0 == 0 }) { return embedded.nonPublicReason }
                return "local NAT64 address"
            }
            if b[0] == 0x20, b[1] == 0x02 { return BrowserNetworkAddress.v4(Array(b[2..<6])).nonPublicReason }
            if b[0] == 0x20, b[1] == 0x01, b[2] == 0x00, b[3] == 0x00 { return "Teredo address" }
            if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return "documentation address" }
            if b[0] == 0x01, b[1] == 0x00, b[2..<8].allSatisfy({ $0 == 0 }) { return "discard address" }
            if b[0] & 0xfe == 0xfc { return "private address" }
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return "link-local address" }
            if b[0] == 0xfe, b[1] & 0xc0 == 0xc0 { return "site-local address" }
            if b[0] == 0xff { return "multicast address" }
            return nil
        }
    }
}

public enum BrowserNetworkVerdict: Sendable, Hashable {
    case allowed
    case denied(String)

    public var denialReason: String? {
        if case .denied(let reason) = self { return reason }
        return nil
    }
}

/// Where a browser target may connect. Checks fail closed: a host that can't be parsed or resolved, or that
/// resolves to any non-public address, is denied unless private-network access is opted into.
///
/// Domain lists are matched like domain grants: an entry covers itself and its subdomains. The block list wins.
public struct BrowserNetworkPolicy: Sendable, Codable, Hashable {
    /// Lets the browser reach loopback, private, link-local, and other non-public addresses.
    public var allowsPrivateNetwork: Bool
    /// When set, the only domains the browser may reach. `nil` allows any public domain.
    public var allowedDomains: [String]?
    public var blockedDomains: [String]

    /// Schemes a page may be loaded over. Everything else is local to the browser or dispatches to another app.
    public static let networkSchemes: Set<String> = ["http", "https", "ws", "wss"]
    /// Pages the browser shows without touching the network.
    public static let localPages: Set<String> = ["about:blank", "about:srcdoc"]
    /// Names that only mean something inside a private network.
    static let privateNameSuffixes = ["localhost", "local", "internal", "intranet", "lan", "home.arpa", "corp"]

    public init(allowsPrivateNetwork: Bool = false, allowedDomains: [String]? = nil, blockedDomains: [String] = []) {
        self.allowsPrivateNetwork = allowsPrivateNetwork
        self.allowedDomains = allowedDomains.map { $0.map(ComputerUseDomain.normalize).filter { !$0.isEmpty } }
        self.blockedDomains = blockedDomains.map(ComputerUseDomain.normalize).filter { !$0.isEmpty }
    }

    /// The check before navigation and on a page's final URL: the scheme, then the host by name.
    public func evaluate(url raw: String) -> BrowserNetworkVerdict {
        if Self.localPages.contains(raw) { return .allowed }
        guard let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased() else {
            return .denied("the URL can't be parsed")
        }
        guard Self.networkSchemes.contains(scheme) else { return .denied("\(scheme): URLs are not allowed") }
        guard let host = components.host, !host.isEmpty else { return .denied("the URL has no host") }
        return evaluate(host: host)
    }

    /// The check on a host by name, before it is resolved. An IP literal is checked as an address.
    public func evaluate(host raw: String) -> BrowserNetworkVerdict {
        let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty else { return .denied("empty host") }
        if let address = BrowserNetworkAddress(host) {
            if let allowedDomains, !allowedDomains.contains(address.description), !allowedDomains.contains(host) {
                return .denied("\(host) is not on the allow list")
            }
            return evaluate(addresses: [address], host: host)
        }
        if let blocked = blockedDomains.first(where: { ComputerUseDomain.matches(host: host, domain: $0) }) {
            return .denied("\(host) is blocked (\(blocked))")
        }
        if let allowedDomains, !allowedDomains.contains(where: { ComputerUseDomain.matches(host: host, domain: $0) }) {
            return .denied("\(host) is not on the allow list")
        }
        if !allowsPrivateNetwork {
            if !host.contains(".") { return .denied("\(host) is a private network name") }
            if let suffix = Self.privateNameSuffixes.first(where: { ComputerUseDomain.matches(host: host, domain: $0) }) {
                return .denied("\(host) is a private network name (.\(suffix))")
            }
        }
        return .allowed
    }

    /// The check after resolution: every address must be public, so a name that resolves to both a public and a
    /// private address can't be steered to the private one.
    public func evaluate(addresses: [BrowserNetworkAddress], host: String) -> BrowserNetworkVerdict {
        guard !addresses.isEmpty else { return .denied("\(host) did not resolve") }
        guard !allowsPrivateNetwork else { return .allowed }
        for address in addresses {
            if let reason = address.nonPublicReason {
                let shown = address.description == host ? host : "\(host) resolves to \(address)"
                return .denied("\(shown), a \(reason); private network access is off")
            }
        }
        return .allowed
    }
}
