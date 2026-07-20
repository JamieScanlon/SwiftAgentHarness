import Foundation

enum ModelPoolOwnerScope {
    /// Returns `nil` when strict tenancy requires an owner but none is present (fail closed / bypass).
    /// Returns `""` when tenancy is off (legacy process-wide shared partition).
    static func resolve(
        ownerAccountID: UUID?,
        tenancyPolicy: TenancyPolicySettings
    ) -> String? {
        guard tenancyPolicy.requireAuthenticatedOwnerOnMutations else {
            return ""
        }
        guard let ownerAccountID else {
            return nil
        }
        return AgentMemoryPathResolver.ownerSegment(ownerAccountID)
    }
}
