import Foundation

/// How a projection transformation affects the cache-stable prefix.
public enum CacheProjectionTransformationKind: String, Sendable, Equatable {
  case cacheNeutral
  case cacheEditing
  case cacheBreaking
}

/// Deliberate reasons the stable prefix may be rebuilt.
public enum CacheBreakEventReason: String, Sendable, Equatable, Codable {
  case sessionStart
  case compactionCommit
  case modeSwitch
  case modelChange
  case providerChange
  case memorySnapshotRefresh
  case manualCompaction
  case cacheExpiry
}

public enum ProjectionStabilityContract {
  public static func isBytePrefixExtension(previous: String, next: String) -> Bool {
    next.hasPrefix(previous)
  }

  public static func firstDivergenceOffset(previous: String, next: String) -> Int? {
    if previous == next { return nil }
    let previousScalars = Array(previous.unicodeScalars)
    let nextScalars = Array(next.unicodeScalars)
    let limit = min(previousScalars.count, nextScalars.count)
    for index in 0..<limit where previousScalars[index] != nextScalars[index] {
      return index
    }
    if previousScalars.count != nextScalars.count {
      return limit
    }
    return nil
  }
}
