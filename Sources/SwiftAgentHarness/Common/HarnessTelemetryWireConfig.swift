import Foundation

/// Opt-in harness telemetry on orchestration payloads (`SAH_HARNESS_WIRE=1`).
enum HarnessTelemetryWireConfig {
    static var enabled: Bool {
        let v = ProcessInfo.processInfo.environment["SAH_HARNESS_WIRE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return v == "1" || v == "true" || v == "yes"
    }
}
