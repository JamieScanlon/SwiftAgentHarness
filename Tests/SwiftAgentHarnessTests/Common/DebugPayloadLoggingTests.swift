import Testing
@testable import SwiftAgentHarness

@Suite("DebugPayloadLogging")
struct DebugPayloadLoggingTests {
    @Test("defaults enabled when env var is unset")
    func defaultsEnabled() {
        #expect(DebugPayloadLogging.isEnabled(environment: [:]) == true)
    }

    @Test("recognizes falsey env var values")
    func falseyValuesDisablePayloadLogging() {
        for value in ["0", "false", "FALSE", "no", "off"] {
            #expect(DebugPayloadLogging.isEnabled(environment: ["SAH_LOG_FULL_PAYLOADS": value]) == false)
        }
    }

    @Test("recognizes truthy env var values")
    func truthyValuesEnablePayloadLogging() {
        for value in ["1", "true", "TRUE", "yes", "on"] {
            #expect(DebugPayloadLogging.isEnabled(environment: ["SAH_LOG_FULL_PAYLOADS": value]) == true)
        }
    }
}
