//
//  Supported JSONL transcript header versions (line 1) and write policy.
//

import Foundation

/// Policy for session JSONL header `version` (first line of `*.jsonl`).
enum SessionJSONLTranscriptFormat {
    /// Oldest header version this build can read.
    static let minSupportedHeaderVersion: Int = 1
    /// Newest header version this build can read (inclusive).
    static let maxSupportedHeaderVersion: Int = 2
    /// Header `version` written for **new** transcript files.
    static let currentWriteHeaderVersion: Int = 2

    static func isSupportedHeaderVersion(_ version: Int) -> Bool {
        version >= minSupportedHeaderVersion && version <= maxSupportedHeaderVersion
    }
}
