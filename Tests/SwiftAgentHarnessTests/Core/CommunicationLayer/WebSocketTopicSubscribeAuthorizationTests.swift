import Foundation
import Testing
@testable import SwiftAgentHarness

struct WebSocketTopicSubscribeAuthorizationTests {
    private func fixtureConversation(id: UUID, owner: UUID?) -> ModelConversation {
        let model = Model(
            id: UUID(),
            protocol: .openAIAPI,
            modelName: "fixture",
            serverURL: URL(string: "http://localhost")!
        )
        return ModelConversation(id: id, model: model, ownerAccountID: owner)
    }

    @Test func deniedWhenConversationNil() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: nil,
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            registryScope: nil
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func allowedWhenNoRegistryScope() {
        let cid = UUID()
        let conv = fixtureConversation(id: cid, owner: UUID())
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            registryScope: nil
        )
        #expect(denied == nil)
    }

    @Test func deniedWhenOwnerMismatchUnderScope() {
        let cid = UUID()
        let scope = UUID()
        let conv = fixtureConversation(id: cid, owner: UUID())
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            registryScope: scope
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func deniedWhenOwnerNilUnderScope() {
        let cid = UUID()
        let scope = UUID()
        let conv = fixtureConversation(id: cid, owner: nil)
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            registryScope: scope
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func allowedWhenOwnerMatchesScope() {
        let cid = UUID()
        let scope = UUID()
        let conv = fixtureConversation(id: cid, owner: scope)
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: false,
            authenticatedOwnerAccountID: nil,
            registryScope: scope
        )
        #expect(denied == nil)
    }

    @Test func deniedWhenStrictTenancyWithoutAuthenticatedOwner() {
        let cid = UUID()
        let conv = fixtureConversation(id: cid, owner: UUID())
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: true,
            authenticatedOwnerAccountID: nil,
            registryScope: nil
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func allowedWhenStrictTenancyOwnerMatches() {
        let cid = UUID()
        let owner = UUID()
        let conv = fixtureConversation(id: cid, owner: owner)
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: true,
            authenticatedOwnerAccountID: owner,
            registryScope: nil
        )
        #expect(denied == nil)
    }

    @Test func deniedWhenStrictTenancyOwnerMismatch() {
        let cid = UUID()
        let conv = fixtureConversation(id: cid, owner: UUID())
        let denied = WebSocketTopicSubscribeAuthorization.deniedReason(
            conversation: conv,
            strictTenancy: true,
            authenticatedOwnerAccountID: UUID(),
            registryScope: nil
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func deniedForConversationsRegistryWhenStrictTenancyWithoutOwner() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForConversationsRegistrySubscribe(
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true),
            authenticatedOwnerAccountID: nil
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func allowedForConversationsRegistryWhenStrictTenancyWithOwner() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForConversationsRegistrySubscribe(
            tenancyPolicy: TenancyPolicySettings(requireAuthenticatedOwnerOnMutations: true),
            authenticatedOwnerAccountID: UUID()
        )
        #expect(denied == nil)
    }

    @Test func allowedForConversationsRegistryWhenTenancyDisabledWithoutOwner() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForConversationsRegistrySubscribe(
            tenancyPolicy: .disabled,
            authenticatedOwnerAccountID: nil
        )
        #expect(denied == nil)
    }

    @Test func traceServerOpenWhenOperatorEnforcementDisabled() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForServerTraceSubscribe(
            authenticatedOwnerAccountID: nil,
            policy: .open
        )
        #expect(denied == nil)
    }

    @Test func traceServerDeniedWhenEnforcedWithoutOwner() {
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForServerTraceSubscribe(
            authenticatedOwnerAccountID: nil,
            policy: ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [UUID()])
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func traceServerDeniedWhenEnforcedWithNonOperatorOwner() {
        let operatorID = UUID()
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForServerTraceSubscribe(
            authenticatedOwnerAccountID: UUID(),
            policy: ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [operatorID])
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func traceServerAllowedWhenEnforcedWithOperatorOwner() {
        let operatorID = UUID()
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForServerTraceSubscribe(
            authenticatedOwnerAccountID: operatorID,
            policy: ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [operatorID])
        )
        #expect(denied == nil)
    }

    @Test func traceSubscribePolicyValidationIssueNilWhenEnforcedWithEmptyAllowlist() {
        let policy = ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [])
        #expect(policy.validationIssue() == nil)
    }

    @Test func operatorScopedSubscribeDeniedWhenEnforcedWithEmptyAllowlist() {
        let operatorID = UUID()
        let denied = WebSocketTopicSubscribeAuthorization.deniedReasonForOperatorScopedSubscribe(
            authenticatedOwnerAccountID: operatorID,
            policy: ServerTraceSubscribePolicy(enforceOperatorAllowlist: true, operatorOwnerIDs: [])
        )
        #expect(denied == WebSocketTopicSubscribeAuthorization.deniedMessage)
    }

    @Test func traceSubscribePolicyValidationIssueNilWhenOpen() {
        #expect(ServerTraceSubscribePolicy.open.validationIssue() == nil)
    }
}
