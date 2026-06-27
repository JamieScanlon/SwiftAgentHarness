import Foundation

/// Canonical `originSurface` identifiers for interactive transcript surfaces.
public enum InteractiveSurfaceID {
    public static let tui = "tui"
    public static let rest = "rest"
    public static let ws = "ws"
    public static let cli = "cli"

    public static let all: Set<String> = [tui, rest, ws, cli]
}
