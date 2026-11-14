#if os(macOS) || os(Linux)
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("Managed Chromium launcher")
struct ManagedChromiumTests {
    private static func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chromium-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func profile(in root: URL, lock: String?, modified: Date) throws -> URL {
        let profile = root.appendingPathComponent("managed-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("cookies".utf8).write(to: profile.appendingPathComponent("Cookies"))
        if let lock {
            try FileManager.default.createSymbolicLink(atPath: profile.appendingPathComponent("SingletonLock").path, withDestinationPath: lock)
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: profile.path)
        return profile
    }

    @Test("The browser's pipe ends are close-on-exec and above the descriptors it reads, so no other child holds them")
    func pipeDescriptors() throws {
        let (read, write) = try ManagedChromium.makePipe()
        defer { close(read); close(write) }
        for descriptor in [read, write] {
            #expect(descriptor > 4)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
        var byte: UInt8 = 7
        #expect(Foundation.write(write, &byte, 1) == 1)
        byte = 0
        #expect(Foundation.read(read, &byte, 1) == 1 && byte == 7)
    }

    @Test("Profiles live in their own folder")
    func profileRoot() {
        let root = ManagedChromiumConfiguration().profileRoot
        #expect(root.lastPathComponent == "SwiftAgentHarness-browser-profiles")
        #expect(root.deletingLastPathComponent().standardizedFileURL == FileManager.default.temporaryDirectory.standardizedFileURL)
    }

    @Test("Profiles whose browser is gone are removed; a running or launching browser's, and other hosts', are kept")
    func staleProfiles() throws {
        let root = try Self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let host = "builder.example"
        let deadPID: Int32 = 99_999_999
        let livePID = getpid()

        let crashed = try Self.profile(in: root, lock: "\(host)-\(deadPID)", modified: now)
        let exitedLongAgo = try Self.profile(in: root, lock: nil, modified: now.addingTimeInterval(-3_600))
        let running = try Self.profile(in: root, lock: "\(host)-\(livePID)", modified: now.addingTimeInterval(-3_600))
        let launching = try Self.profile(in: root, lock: nil, modified: now.addingTimeInterval(-5))
        let otherHost = try Self.profile(in: root, lock: "other.example-\(deadPID)", modified: now.addingTimeInterval(-3_600))
        let hyphenatedHost = try Self.profile(in: root, lock: "Mac-Studio.HomeNet-\(livePID)", modified: now.addingTimeInterval(-3_600))
        let unrelated = root.appendingPathComponent("someone-else", isDirectory: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)], ofItemAtPath: unrelated.path)

        ManagedChromium.removeStaleProfiles(in: root, hostName: host, now: now)
        func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
        #expect(!exists(crashed))
        #expect(!exists(exitedLongAgo))
        #expect(exists(running))
        #expect(exists(launching))
        #expect(exists(otherHost))
        #expect(exists(hyphenatedHost))
        #expect(exists(unrelated), "only the launcher's own profiles are touched")

        ManagedChromium.removeStaleProfiles(in: root, hostName: "Mac-Studio.HomeNet", now: now)
        #expect(exists(hyphenatedHost), "its browser, this process, is running")
    }

    @Test("Sweeping a folder that doesn't exist does nothing")
    func missingRoot() {
        ManagedChromium.removeStaleProfiles(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"), hostName: "h", now: Date())
    }
}
#endif
