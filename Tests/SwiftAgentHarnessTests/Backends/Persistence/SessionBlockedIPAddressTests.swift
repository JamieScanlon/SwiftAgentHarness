import Foundation
@testable import SwiftAgentHarness
import Testing

@Suite("Session blocked IP address")
struct SessionBlockedIPAddressTests {
    @Test func blocksMetadataEndpoint() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "169.254.169.254"))
        #expect(SessionBlockedIPAddress.isBlockedIPv4([169, 254, 169, 254]))
    }

    @Test func blocksCGNAT() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "100.64.0.1"))
        #expect(SessionBlockedIPAddress.isBlockedIPv4([100, 64, 0, 1]))
    }

    @Test func blocksRFC1918() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "10.0.0.1"))
        #expect(SessionBlockedIPAddress.isBlocked(host: "192.168.1.1"))
        #expect(SessionBlockedIPAddress.isBlocked(host: "172.16.0.1"))
        #expect(SessionBlockedIPAddress.isBlocked(host: "127.0.0.1"))
    }

    @Test func allowsPublicIPv4() {
        #expect(!SessionBlockedIPAddress.isBlocked(host: "8.8.8.8"))
        #expect(!SessionBlockedIPAddress.isBlockedIPv4([8, 8, 8, 8]))
    }

    @Test func blocksLoopbackIPv6() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "::1"))
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = 1
        #expect(SessionBlockedIPAddress.isBlockedIPv6(bytes))
    }

    @Test func blocksIPv4MappedPrivateAddress() {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[10] = 0xff
        bytes[11] = 0xff
        bytes[12] = 10
        bytes[13] = 0
        bytes[14] = 0
        bytes[15] = 1
        #expect(SessionBlockedIPAddress.isBlockedIPv6(bytes))
    }

    @Test func blocksIPv4MappedPrivateAddressTextual() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "::ffff:10.0.0.1"))
        #expect(SessionBlockedIPAddress.isBlocked(host: "::ffff:127.0.0.1"))
        #expect(SessionBlockedIPAddress.isBlocked(host: "::ffff:169.254.169.254"))
    }

    @Test func blocksIPv4MappedPrivateAddressHexGroups() {
        #expect(SessionBlockedIPAddress.isBlocked(host: "::ffff:0a00:0001"))
    }

    @Test func blocksIPv4MappedPrivateSockaddr() {
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = UInt16(443).bigEndian
        sin6.sin6_addr = in6_addr(
            __u6_addr: in6_addr.__Unnamed_union___u6_addr(
                __u6_addr8: (
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 10, 0, 0, 1
                )
            )
        )
        let data = withUnsafeBytes(of: &sin6) { Data($0) }
        #expect(SessionBlockedIPAddress.isBlockedSockaddr(data))
    }

    @Test func allowsIPv4MappedPublicAddressTextual() {
        #expect(!SessionBlockedIPAddress.isBlocked(host: "::ffff:8.8.8.8"))
    }

    @Test func blocksUnspecifiedIPv4Range() {
        #expect(SessionBlockedIPAddress.isBlockedIPv4([0, 0, 0, 0]))
        #expect(SessionBlockedIPAddress.isBlockedIPv4([0, 1, 2, 3]))
        #expect(SessionBlockedIPAddress.isBlocked(host: "0.1.2.3"))
    }

    @Test func blocksUnspecifiedIPv6() {
        #expect(SessionBlockedIPAddress.isBlockedIPv6([UInt8](repeating: 0, count: 16)))
        #expect(SessionBlockedIPAddress.isBlocked(host: "::"))
    }

    @Test func blocksUnspecifiedIPv4Sockaddr() {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = UInt16(443).bigEndian
        _ = "0.0.0.0".withCString { inet_pton(AF_INET, $0, &sin.sin_addr) }
        let data = withUnsafeBytes(of: &sin) { Data($0) }
        #expect(SessionBlockedIPAddress.isBlockedSockaddr(data))
    }

    @Test func blocksUnspecifiedIPv6Sockaddr() {
        var sin6 = sockaddr_in6()
        sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        sin6.sin6_family = sa_family_t(AF_INET6)
        sin6.sin6_port = UInt16(443).bigEndian
        _ = "::".withCString { inet_pton(AF_INET6, $0, &sin6.sin6_addr) }
        let data = withUnsafeBytes(of: &sin6) { Data($0) }
        #expect(SessionBlockedIPAddress.isBlockedSockaddr(data))
    }
}
