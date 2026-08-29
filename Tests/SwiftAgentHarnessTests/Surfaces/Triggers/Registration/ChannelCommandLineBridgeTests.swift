import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

@Suite("/channel argument bridge")
struct ChannelCommandLineBridgeTests {
    private func slash(_ args: String) -> JSON {
        .object(["commandName": .string("channel"), "args": .string(args)])
    }

    private func field(_ json: JSON?, _ key: String) -> String? {
        guard case .object(let dict)? = json, case .string(let value)? = dict[key] else { return nil }
        return value
    }

    @Test("a bare invocation lists")
    func bareLists() {
        #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash("")), "action") == "list")
    }

    @Test("list aliases map to list")
    func listAliases() {
        for alias in ["list", "ls", "status"] {
            #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash(alias)), "action") == "list")
        }
    }

    /// `/channel status slack` names one channel, so it is a lookup. Only the listing verb is
    /// promoted — a mutation verb with a channel stays a mutation verb.
    @Test("naming a channel promotes a listing to a lookup")
    func namedChannelPromotesToGet() {
        let mapped = TriggerToolArgumentBridge.channelArguments(from: slash("status slack"))
        #expect(field(mapped, "action") == "get")
        #expect(field(mapped, "channel") == "slack")
    }

    @Test("get aliases map to get")
    func getAliases() {
        for alias in ["get", "show", "info"] {
            let mapped = TriggerToolArgumentBridge.channelArguments(from: slash("\(alias) telegram"))
            #expect(field(mapped, "action") == "get")
            #expect(field(mapped, "channel") == "telegram")
        }
    }

    @Test("mutation verbs map through so the provider can explain the refusal")
    func mutationVerbsMapThrough() {
        #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash("disable slack")), "action") == "disable")
        #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash("pause slack")), "action") == "disable")
        #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash("enable slack")), "action") == "enable")
        #expect(field(TriggerToolArgumentBridge.channelArguments(from: slash("resume slack")), "action") == "enable")
    }

    /// `ChannelListenerRegistry.reload(channel:)` exists but no client exposes it, so mapping the
    /// verb through would produce a refusal naming a command nobody can run.
    @Test("reload is not mapped while it has no owner client")
    func reloadUnmapped() {
        #expect(TriggerToolArgumentBridge.channelArguments(from: slash("reload slack")) == nil)
        #expect(TriggerToolArgumentBridge.channelArguments(from: slash("restart slack")) == nil)
    }

    @Test("an unrecognised verb does not map")
    func unknownVerbUnmapped() {
        #expect(TriggerToolArgumentBridge.channelArguments(from: slash("frobnicate slack")) == nil)
    }

    @Test("a --channel option is equivalent to the positional form")
    func channelOption() {
        let mapped = TriggerToolArgumentBridge.channelArguments(from: slash("get --channel discord"))
        #expect(field(mapped, "channel") == "discord")
    }

    @Test("model-shaped arguments are not treated as a slash dispatch")
    func modelArgumentsAreNotSlash() {
        let modelCall = JSON.object(["action": .string("list")])
        #expect(TriggerToolArgumentBridge.isSlashDispatch(modelCall) == false)
        #expect(TriggerToolArgumentBridge.isSlashDispatch(slash("list")))
    }
}

@Suite("Channel tool classification")
struct ChannelToolClassificationTests {
    /// Read-only is not an exemption: a caller with no authority to change a channel has no reason
    /// to enumerate the owner's, which is the same rule that already covers `schedule_list`.
    @Test("channel is a control-plane tool")
    func channelIsControlPlane() {
        #expect(ToolControlPlaneClassification.isControlPlane(ToolControlPlaneClassification.TriggerTools.channel))
    }

    @Test("channel is withheld from confined profiles")
    func channelIsDeniedInConfinedProfiles() {
        let canonical = ToolNamePolicyNormalization.canonical(
            ToolControlPlaneClassification.TriggerTools.channel
        )
        #expect(ToolControlPlaneClassification.confinedProfileDenyTokens.contains(canonical))
    }

    /// Every field the tool renders is an enum or a bool. The one attacker-influenced string in the
    /// underlying type — the fatal *message* — never leaves `ChannelStatusSummary`.
    @Test("channel results are status-only, unlike schedule_list")
    func channelIsStatusOnly() {
        let statusOnly = ToolControlPlaneClassification.TriggerTools.statusOnlyResults
        #expect(statusOnly.contains(ToolControlPlaneClassification.TriggerTools.channel))
        #expect(statusOnly.contains(ToolControlPlaneClassification.TriggerTools.scheduleList) == false)
    }
}
