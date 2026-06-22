import Foundation

/// Resolves the host-provided **PromptConfig.json** used to configure the harness.
///
/// `PromptConfig.json` is expected to be supplied by the *host* that embeds SwiftAgentHarness
/// (an app or server target), not by the library itself. Resolution walks a precedence chain so
/// hosts can pick whichever delivery mechanism fits their deployment:
///
/// 1. **Programmatic override** — ``configure(url:)`` / ``configure(bundle:)`` / ``configure(data:)``.
///    The most explicit and testable option; resolved before anything else.
/// 2. **Environment variable** — a file path in `SAH_PROMPT_CONFIG` (tilde-expanded). Ideal for
///    server deployments where the config is a deployed file rather than a bundled resource.
/// 3. **`Bundle.main`** — picks up `PromptConfig.json` bundled into the host app/executable target.
/// 4. **Host-registered bundles** — added via ``registerBundle(_:)`` for multi-module hosts.
/// 5. **`Bundle.module`** — the library's own copy, if one is ever shipped.
/// 6. **SwiftPM test resource bundles** — fallback so unit tests resolve their bundled copy.
///
/// The first location that yields a readable config wins.
public enum PromptConfigBundleResource {
    /// Environment variable holding an absolute (or tilde-prefixed) path to `PromptConfig.json`.
    public static let environmentKey = "SAH_PROMPT_CONFIG"

    private static let resourceName = "PromptConfig"
    private static let resourceExtension = "json"
    private static let testResourceBundleSuffix = "SwiftAgentHarness_SwiftAgentHarnessTests.bundle"

    private enum Override {
        case url(URL)
        case bundle(Bundle)
        case data(Data)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var override: Override?
    nonisolated(unsafe) private static var registeredBundles: [Bundle] = []

    // MARK: - Host configuration

    /// Use an explicit `PromptConfig.json` file at `url`. Takes precedence over all other locations.
    public static func configure(url: URL) {
        setOverride(.url(url))
    }

    /// Resolve `PromptConfig.json` from `bundle` (e.g. a host module's resource bundle).
    public static func configure(bundle: Bundle) {
        setOverride(.bundle(bundle))
    }

    /// Supply the raw `PromptConfig.json` contents directly (in-memory). Useful for servers that load
    /// configuration from a remote source, and for tests.
    public static func configure(data: Data) {
        setOverride(.data(data))
    }

    /// Register an additional bundle to search after `Bundle.main` but before `Bundle.module`.
    public static func registerBundle(_ bundle: Bundle) {
        lock.lock()
        defer { lock.unlock() }
        if !registeredBundles.contains(where: { $0.bundlePath == bundle.bundlePath }) {
            registeredBundles.append(bundle)
        }
    }

    /// Clears any programmatic override and registered bundles. Intended for test isolation.
    static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        override = nil
        registeredBundles = []
    }

    // MARK: - Resolution

    /// First on-disk `PromptConfig.json` location that exists, in precedence order.
    ///
    /// Returns `nil` when no file-backed location resolves. Note a ``configure(data:)`` override is
    /// in-memory only and is therefore not reflected here; use ``data()`` to read configured contents.
    static func url() -> URL? {
        candidateURLs().first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Raw contents of the resolved `PromptConfig.json`, honoring an in-memory ``configure(data:)``
    /// override before falling back to the file-backed precedence chain.
    static func data() -> Data? {
        if case .data(let data)? = snapshotOverride() {
            return data
        }
        for candidate in candidateURLs() {
            if let data = try? Data(contentsOf: candidate) {
                return data
            }
        }
        return nil
    }

    // MARK: - Internals

    private static func candidateURLs() -> [URL] {
        let (override, registered) = snapshot()
        var urls: [URL] = []

        if let override {
            switch override {
            case .url(let url):
                urls.append(url)
            case .bundle(let bundle):
                if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
                    urls.append(url)
                }
            case .data:
                break
            }
        }

        if let envURL = environmentOverrideURL() {
            urls.append(envURL)
        }

        for bundle in candidateBundles(registered: registered) {
            if let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) {
                urls.append(url)
            }
        }

        return urls
    }

    private static func environmentOverrideURL() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    private static func candidateBundles(registered: [Bundle]) -> [Bundle] {
        var seen = Set<String>()
        var bundles: [Bundle] = []

        func append(_ bundle: Bundle?) {
            guard let bundle, seen.insert(bundle.bundlePath).inserted else { return }
            bundles.append(bundle)
        }

        append(Bundle.main)
        registered.forEach(append)
        append(Bundle.module)

        for bundle in Bundle.allBundles {
            append(bundle)

            let base = bundle.bundleURL.deletingLastPathComponent()
            append(Bundle(url: base.appendingPathComponent(testResourceBundleSuffix)))

            if bundle.bundleURL.pathExtension == "xctest" {
                let resourcesDirectory = bundle.bundleURL.appendingPathComponent("Contents/Resources")
                if let children = try? FileManager.default.contentsOfDirectory(
                    at: resourcesDirectory,
                    includingPropertiesForKeys: nil
                ) {
                    for child in children where child.pathExtension == "bundle" {
                        append(Bundle(url: child))
                    }
                }
            }
        }

        return bundles
    }

    private static func setOverride(_ value: Override) {
        lock.lock()
        defer { lock.unlock() }
        override = value
    }

    private static func snapshot() -> (Override?, [Bundle]) {
        lock.lock()
        defer { lock.unlock() }
        return (override, registeredBundles)
    }

    private static func snapshotOverride() -> Override? {
        lock.lock()
        defer { lock.unlock() }
        return override
    }
}
