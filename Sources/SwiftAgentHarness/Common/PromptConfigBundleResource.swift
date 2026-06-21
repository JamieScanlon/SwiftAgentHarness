import Foundation

/// Resolves bundled **PromptConfig.json** for the library and for SwiftPM test runs.
///
/// Production hosts may ship PromptConfig in ``Bundle.module``. Unit tests bundle a minimal copy
/// in the test target only; this helper falls back to SwiftPM test resource bundles when the module
/// bundle has no copy.
enum PromptConfigBundleResource {
    private static let testResourceBundleSuffix = "SwiftAgentHarness_SwiftAgentHarnessTests.bundle"

    static func url() -> URL? {
        for bundle in candidateBundles() {
            if let url = bundle.url(forResource: "PromptConfig", withExtension: "json") {
                return url
            }
        }
        return nil
    }

    private static func candidateBundles() -> [Bundle] {
        var seen = Set<String>()
        var bundles: [Bundle] = []

        func append(_ bundle: Bundle?) {
            guard let bundle, seen.insert(bundle.bundlePath).inserted else { return }
            bundles.append(bundle)
        }

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
}
