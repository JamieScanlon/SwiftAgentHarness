import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Browser network policy")
struct BrowserNetworkPolicyTests {
    private let policy = BrowserNetworkPolicy()

    @Test("Non-public IPv4 ranges are denied", arguments: [
        "0.0.0.0", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255",
        "192.0.0.8", "192.0.2.1", "192.168.1.1", "198.18.0.1", "198.51.100.7", "203.0.113.9", "224.0.0.1", "255.255.255.255",
    ])
    func privateV4(_ address: String) {
        #expect(policy.evaluate(host: address).denialReason != nil)
    }

    @Test("Public IPv4 addresses are allowed", arguments: ["8.8.8.8", "93.184.216.34", "172.32.0.1", "100.128.0.1", "1.1.1.1"])
    func publicV4(_ address: String) {
        #expect(policy.evaluate(host: address) == .allowed)
    }

    @Test("IPv4 spellings that parsers pass through are read as the address they mean", arguments: [
        "2130706433", "0x7f000001", "0177.0.0.1", "127.1",
    ])
    func obfuscatedLoopback(_ spelling: String) {
        #expect(BrowserNetworkAddress(spelling) == .v4([127, 0, 0, 1]))
        #expect(policy.evaluate(url: "http://\(spelling)/").denialReason != nil)
    }

    @Test("Non-public IPv6 forms are denied, including ones that embed a private IPv4 address", arguments: [
        "::1", "::", "[::1]", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "::127.0.0.1", "64:ff9b::a00:1", "64:ff9b:1::1",
        "2002:7f00:1::", "2001:0:4136:e378::1", "2001:db8::1", "fc00::1", "fd12:3456::1", "fe80::1%en0", "fec0::1", "ff02::1",
    ])
    func privateV6(_ address: String) {
        #expect(policy.evaluate(host: address).denialReason != nil)
    }

    @Test("Public IPv6 addresses, and IPv6 forms that embed public IPv4, are allowed", arguments: [
        "2606:4700:4700::1111", "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:808:808::",
    ])
    func publicV6(_ address: String) {
        #expect(policy.evaluate(host: address) == .allowed)
    }

    @Test("Private network names are denied before resolution", arguments: [
        "localhost", "app.localhost", "printer.local", "metadata.google.internal", "intranet", "router.lan", "nas.home.arpa",
    ])
    func privateNames(_ host: String) {
        #expect(policy.evaluate(host: host).denialReason != nil)
        #expect(BrowserNetworkPolicy(allowsPrivateNetwork: true).evaluate(host: host) == .allowed)
    }

    @Test("A name that resolves to any non-public address is denied")
    func rebinding() {
        let mixed = [BrowserNetworkAddress("93.184.216.34")!, BrowserNetworkAddress("127.0.0.1")!]
        #expect(policy.evaluate(addresses: mixed, host: "rebind.example")
            == .denied("rebind.example resolves to 127.0.0.1, a loopback address; private network access is off"))
        #expect(policy.evaluate(addresses: [BrowserNetworkAddress("93.184.216.34")!], host: "example.com") == .allowed)
        #expect(BrowserNetworkPolicy(allowsPrivateNetwork: true).evaluate(addresses: mixed, host: "rebind.example") == .allowed)
    }

    @Test("A name that resolves to nothing is denied")
    func unresolved() {
        #expect(policy.evaluate(addresses: [], host: "nowhere.example") == .denied("nowhere.example did not resolve"))
    }

    @Test("Only web schemes load over the network; blank pages are local")
    func schemes() {
        #expect(policy.evaluate(url: "https://example.com/a") == .allowed)
        #expect(policy.evaluate(url: "wss://example.com/socket") == .allowed)
        #expect(policy.evaluate(url: "about:blank") == .allowed)
        #expect(policy.evaluate(url: "file:///etc/passwd") == .denied("file: URLs are not allowed"))
        #expect(policy.evaluate(url: "chrome://settings") == .denied("chrome: URLs are not allowed"))
        #expect(policy.evaluate(url: "javascript:alert(1)") == .denied("javascript: URLs are not allowed"))
        #expect(policy.evaluate(url: "http://169.254.169.254/latest/meta-data").denialReason != nil)
    }

    @Test("The block list wins over the allow list, and both cover subdomains")
    func domainLists() {
        let listed = BrowserNetworkPolicy(allowedDomains: ["example.com", "*.cdn.net"], blockedDomains: ["admin.example.com"])
        #expect(listed.evaluate(host: "www.example.com") == .allowed)
        #expect(listed.evaluate(host: "static.cdn.net") == .allowed)
        #expect(listed.evaluate(host: "admin.example.com") == .denied("admin.example.com is blocked (admin.example.com)"))
        #expect(listed.evaluate(host: "x.admin.example.com").denialReason != nil)
        #expect(listed.evaluate(host: "other.org") == .denied("other.org is not on the allow list"))
        #expect(listed.evaluate(host: "8.8.8.8") == .denied("8.8.8.8 is not on the allow list"))
        #expect(BrowserNetworkPolicy(blockedDomains: ["Tracker.COM"]).evaluate(host: "ads.tracker.com").denialReason != nil)
    }

    @Test("Addresses print in their canonical form")
    func printing() {
        #expect(BrowserNetworkAddress("0x7f.1")?.description == "127.0.0.1")
        #expect(BrowserNetworkAddress("[0:0:0:0:0:0:0:1]")?.description == "::1")
        #expect(BrowserNetworkAddress("example.com") == nil)
        #expect(BrowserNetworkAddress("1.2.3.4.5") == nil)
    }
}
