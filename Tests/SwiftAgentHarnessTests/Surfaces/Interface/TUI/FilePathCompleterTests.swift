import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("FilePathCompleter")
struct FilePathCompleterTests {
    /// Builds a throwaway tree:
    ///   root/README.md, root/Package.swift, root/.hidden
    ///   root/Sources/Alpha.swift, root/Sources/Beta.swift
    ///   root/Sources/Nested/Deep.swift
    private func makeTree() throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-completer-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/Nested")
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["README.md", "Package.swift", ".hidden"] {
            manager.createFile(atPath: root.appendingPathComponent(path).path, contents: Data("x".utf8))
        }
        for path in ["Sources/Alpha.swift", "Sources/Beta.swift", "Sources/Nested/Deep.swift"] {
            manager.createFile(atPath: root.appendingPathComponent(path).path, contents: Data("x".utf8))
        }
        return root
    }

    private func cleanUp(_ root: URL) {
        try? FileManager.default.removeItem(at: root)
    }

    @Test("Empty token lists the root")
    func listsRoot() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        let labels = FilePathCompleter(root: root).suggestions(for: "").map(\.label)
        #expect(labels.contains("README.md"))
        #expect(labels.contains("Package.swift"))
        #expect(labels.contains("Sources/"))
    }

    @Test("Directories keep a trailing slash so completion descends")
    func directoriesKeepSlash() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        let suggestion = try #require(
            FilePathCompleter(root: root).suggestions(for: "Sour").first
        )
        #expect(suggestion.label == "Sources/")
        #expect(suggestion.insertionText == "@Sources/")
    }

    @Test("Prefix filters within a subdirectory")
    func filtersWithinSubdirectory() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        let labels = FilePathCompleter(root: root).suggestions(for: "Sources/Al").map(\.label)
        #expect(labels == ["Alpha.swift"])
    }

    @Test("Insertion carries the root-relative path")
    func insertionIsRelative() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        let suggestion = try #require(
            FilePathCompleter(root: root).suggestions(for: "Sources/Nested/De").first
        )
        #expect(suggestion.insertionText == "@Sources/Nested/Deep.swift")
    }

    @Test("Hidden files are excluded by default and included on request")
    func hiddenFiles() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        #expect(!FilePathCompleter(root: root).suggestions(for: "").map(\.label).contains(".hidden"))
        let withHidden = FilePathCompleter(root: root, includeHidden: true).suggestions(for: "")
        #expect(withHidden.map(\.label).contains(".hidden"))
    }

    @Test("Traversal above the root is refused")
    func refusesEscape() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        // A completer that will walk to /etc turns a convenience into a way to attach
        // arbitrary host files to a turn.
        let completer = FilePathCompleter(root: root.appendingPathComponent("Sources"))
        #expect(completer.suggestions(for: "../").isEmpty)
        #expect(completer.suggestions(for: "../../").isEmpty)
        #expect(completer.suggestions(for: "/etc/").isEmpty)
    }

    @Test("A symlink out of the root is refused")
    func refusesSymlinkEscape() throws {
        // `standardizedFileURL` only collapses `..` lexically, so a lexical prefix check
        // lets `root/link -> /outside` through — defeating the confinement entirely.
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("tui-link-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        manager.createFile(atPath: outside.appendingPathComponent("secret.txt").path, contents: Data("s".utf8))
        try manager.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)

        let completer = FilePathCompleter(root: root)
        #expect(completer.suggestions(for: "link/").isEmpty)
        #expect(!completer.suggestions(for: "link/").map(\.label).contains("secret.txt"))
    }

    @Test("Unconfined completers may leave the root")
    func unconfinedAllowsEscape() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        let completer = FilePathCompleter(
            root: root.appendingPathComponent("Sources"),
            confinesToRoot: false
        )
        #expect(!completer.suggestions(for: "../").isEmpty)
    }

    @Test("Unconfined completion keeps an absolute path usable")
    func unconfinedAbsoluteInsertion() throws {
        // Falling back to `lastPathComponent` here produced `@README.md` for a file that
        // is nowhere near the workspace — an unresolvable token.
        let root = try makeTree()
        defer { cleanUp(root) }
        let completer = FilePathCompleter(
            root: root.appendingPathComponent("Sources"),
            confinesToRoot: false
        )
        let suggestion = try #require(
            completer.suggestions(for: root.path + "/READ").first { $0.label == "README.md" }
        )
        #expect(suggestion.insertionText == "@" + root.path + "/README.md")
    }

    @Test("A symlinked file inside the root keeps its in-root path")
    func symlinkedFileKeepsInRootPath() throws {
        // Resolving the entry would insert the symlink's target — leaking a path outside
        // the workspace. Using only its last component would drop the subdirectory and
        // point at a file that isn't there. Neither is right; the typed path is.
        let manager = FileManager.default
        let base = manager.temporaryDirectory.appendingPathComponent("tui-filelink-\(UUID().uuidString)")
        let root = base.appendingPathComponent("root")
        let outside = base.appendingPathComponent("outside")
        try manager.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: base) }
        let target = outside.appendingPathComponent("secret.txt")
        manager.createFile(atPath: target.path, contents: Data("s".utf8))
        try manager.createSymbolicLink(
            at: root.appendingPathComponent("Sources/link.txt"),
            withDestinationURL: target
        )

        let suggestion = try #require(
            FilePathCompleter(root: root).suggestions(for: "Sources/lin").first
        )
        #expect(suggestion.insertionText == "@Sources/link.txt")
        #expect(!suggestion.insertionText.contains("secret"))
        #expect(!suggestion.insertionText.contains(outside.path))
    }

    @Test("Results are bounded")
    func boundedResults() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("tui-many-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { cleanUp(root) }
        for index in 0..<50 {
            manager.createFile(atPath: root.appendingPathComponent("file\(index).txt").path, contents: Data())
        }
        #expect(FilePathCompleter(root: root, maximumResults: 7).suggestions(for: "").count == 7)
    }

    @Test("A missing directory yields nothing rather than throwing")
    func missingDirectory() throws {
        let root = try makeTree()
        defer { cleanUp(root) }
        #expect(FilePathCompleter(root: root).suggestions(for: "NoSuchDir/x").isEmpty)
    }

    @Test("Token splitting separates directory from name prefix")
    func tokenSplit() {
        #expect(FilePathCompleter.split("Sources/Sur").directory == "Sources")
        #expect(FilePathCompleter.split("Sources/Sur").namePrefix == "Sur")
        #expect(FilePathCompleter.split("READ").directory == "")
        #expect(FilePathCompleter.split("READ").namePrefix == "READ")
        #expect(FilePathCompleter.split("Sources/").namePrefix == "")
    }
}
