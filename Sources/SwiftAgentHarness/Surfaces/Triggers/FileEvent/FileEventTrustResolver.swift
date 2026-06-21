import Foundation

enum FileEventTrustResolver {
    static func resolve(for eventURL: URL) -> FileEventTrustSidecar {
        let sidecarURL = FileEventQueueLayout.trustSidecarURL(for: eventURL)
        guard FileManager.default.fileExists(atPath: sidecarURL.path),
              let data = try? Data(contentsOf: sidecarURL),
              let sidecar = try? JSONDecoder().decode(FileEventTrustSidecar.self, from: data) else {
            return FileEventTrustSidecar(trust: .unknownParty)
        }
        return sidecar
    }
}
