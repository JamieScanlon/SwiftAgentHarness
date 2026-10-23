import Foundation
import Logging
import SwiftAgentKit

/// Runs the Pool's selection pipeline for `decide` roles: resolve → hard-filter → rank → cascade (one stage) →
/// fall back (availability errors only, inside the compat group when compat-bound) → route receipt.
public actor ModelPoolDecisionDispatcher {
    public typealias Clock = @Sendable () -> ContinuousClock.Instant

    private let candidates: any ContractCandidateSource
    private let providers: any DecisionProviderResolving
    private let roles: RoleBindingResolver
    private let emulator: (any DecisionEmulationLLMProviding)?
    private let scheduler: any ModelCallScheduling
    private let budgetAccounting: any BudgetAccounting
    private let budgetPolicy: BudgetPolicy
    private let receipts: any RouteReceiptRecording
    private let cache: DecisionResponseCache?
    /// Optional `router` role input to the rank stage. Never consulted for pinned roles or for the router's own calls.
    private let router: ModelPoolRouter?
    private let now: Clock
    private let logger: Logger
    /// `(role, version)` pairs already warned about, so untuned answers log once instead of on every call.
    private var warnedUntuned = Set<String>()

    /// How many rejected candidates a receipt lists for "why not X".
    static let rankedOutLimit = 5

    public init(
        candidates: any ContractCandidateSource,
        providers: any DecisionProviderResolving = RegistryDecisionProviderResolver(),
        roles: RoleBindingResolver,
        emulator: (any DecisionEmulationLLMProviding)? = nil,
        scheduler: any ModelCallScheduling = NoOpModelCallScheduler(),
        budgetAccounting: any BudgetAccounting = AlwaysAllowBudgetAccounting(),
        budgetPolicy: BudgetPolicy = .disabled,
        receipts: any RouteReceiptRecording = NoOpRouteReceiptRecorder(),
        cache: DecisionResponseCache? = nil,
        router: ModelPoolRouterConfiguration? = nil,
        now: @escaping Clock = { ContinuousClock.now },
        logger: Logger? = nil
    ) {
        self.candidates = candidates
        self.providers = providers
        self.roles = roles
        self.emulator = emulator
        self.scheduler = scheduler
        self.budgetAccounting = budgetAccounting
        self.budgetPolicy = budgetPolicy
        self.receipts = receipts
        self.cache = cache
        self.router = router.map(ModelPoolRouter.init(configuration:))
        self.now = now
        self.logger = logger ?? Logger(label: "SwiftAgentHarness.ModelPool.Decisions")
    }

    // MARK: - Public surface

    /// Answers `request` for `role`. Never throws: failures surface as ``DecisionOutcome/error`` with the policy's
    /// conservative ``DecisionPolicy/onError`` verdict, and every call emits a receipt.
    public func decide(
        _ request: DecisionRequest,
        role: ModelRole,
        policy: DecisionPolicy? = nil,
        context: DecisionCallContext = DecisionCallContext()
    ) async -> DecisionOutcome {
        let start = now()
        var receipt = RouteReceipt(
            conversationID: context.conversationID,
            runID: context.runID,
            role: role,
            contract: .decide,
            requested: context.pin ?? role.rawValue
        )

        func fail(_ error: DecisionDispatchError) async -> DecisionOutcome {
            receipt.latencyMs = Self.milliseconds(now() - start)
            if case .provider(let classification, _) = error { receipt.errorClassification = classification }
            let evaluation = policy?.evaluateFailure()
            if let evaluation, let policy {
                receipt.decision = RouteReceipt.Decision(evaluation: evaluation, question: policy.question)
            }
            await receipts.record(receipt)
            return DecisionOutcome(result: nil, evaluation: evaluation, receipt: receipt, error: error)
        }

        do {
            try request.validate()
        } catch {
            return await fail(.invalidRequest(String(describing: error)))
        }
        if let policy {
            do { try policy.validate() } catch let error as DecisionPolicyValidationError {
                return await fail(.invalidPolicy(error))
            } catch {
                return await fail(.invalidRequest(String(describing: error)))
            }
        }
        guard let binding = roles.overlaying(context.rolePatches).resolve(role, pin: context.pin) else {
            return await fail(.roleUnbound(role))
        }
        guard binding.contract == .decide else {
            return await fail(.contractMismatch(role: role, contract: binding.contract))
        }

        let entries = await candidates.allContractEntries()
        let plan: CandidatePlan
        switch buildPlan(request: request, binding: binding, policy: policy, context: context, entries: entries) {
        case .success(let built): plan = built
        case .failure(let error):
            receipt.rankedOut = []
            return await fail(error)
        }
        receipt.rankedOut = Array(plan.rejected.prefix(Self.rankedOutLimit))
        let ordered = await routerRanked(plan.ordered, request: request, role: role, binding: binding, context: context, receipt: &receipt)

        // Stage 1 with fallback.
        let stage1 = await dispatch(request, over: ordered, binding: binding, context: context, receipt: &receipt)
        guard case .success(let first) = stage1 else {
            if case .failure(let error) = stage1 { return await fail(error) }
            return await fail(.noCandidate(role: role, localityRestricted: binding.locality != .any))
        }
        apply(first, requested: Self.requestedNames(binding, policy: policy), to: &receipt)

        // Stage 2: at most one escalation, declared on the policy (or, without a policy, on the binding).
        let escalation = policy?.escalate.map { RoleCascade(to: $0.to, when: $0.when) } ?? binding.cascade
        var final = first
        var firstStage: DecisionResult?
        if let escalation,
           !first.candidate.entry.isNamed(escalation.to),
           escalation.when.matches(first.result, defaultQuestion: policy?.question) {
            firstStage = first.result
            let firstResolved = receipt.resolved
            var target: [PlannedCandidate] = []
            if let escalated = escalationCandidate(escalation.to, request: request, binding: binding, entries: entries) {
                target = [escalated]
            }
            var stage2Receipt = receipt
            let stage2 = await dispatch(request, over: target, binding: binding, context: context, receipt: &stage2Receipt)
            receipt.fallback = stage2Receipt.fallback
            switch stage2 {
            case .success(let second):
                final = second
                apply(second, requested: Self.requestedNames(binding, policy: policy), to: &receipt)
                receipt.costUSD = Self.sum(first.costUSD, second.costUSD)
                receipt.requestIDs = first.result.requestIDs + second.result.requestIDs
                receipt.cascade = RouteReceipt.Cascade(
                    escalated: true, reason: Self.describe(escalation.when), firstStage: firstResolved
                )
            case .failure(let error):
                receipt.cascade = RouteReceipt.Cascade(
                    escalated: true, reason: "stage 2 failed: \(Self.describe(escalation.when))", firstStage: firstResolved
                )
                receipt.costUSD = first.costUSD
                // The escalation target is final; when it cannot answer, the call fails conservatively.
                var outcome = await fail(error)
                outcome.firstStage = firstStage
                return outcome
            }
        } else if escalation != nil {
            receipt.cascade = RouteReceipt.Cascade(escalated: false)
        }

        receipt.latencyMs = Self.milliseconds(now() - start)
        var evaluation: DecisionEvaluation?
        if let policy {
            let evaluated = evaluate(final, policy: policy, role: role)
            evaluation = evaluated
            receipt.decision = RouteReceipt.Decision(evaluation: evaluated, question: policy.question)
        }
        await receipts.record(receipt)
        return DecisionOutcome(result: final.result, firstStage: firstStage, evaluation: evaluation, receipt: receipt)
    }

    /// Pre-connects the top candidate for `role` so the first call does not pay a cold handshake, then probes each
    /// configured alias once and warns when it no longer serves the pinned version. Probes are billed calls.
    @discardableResult
    public func warm(role: ModelRole, request: DecisionRequest) async -> [DecisionAliasProbe] {
        guard let binding = roles.resolve(role), binding.contract == .decide else { return [] }
        let entries = await candidates.allContractEntries()
        guard case .success(let plan) = buildPlan(
            request: request, binding: binding, policy: nil, context: DecisionCallContext(), entries: entries
        ) else { return [] }
        if let top = plan.ordered.first, case .provider(let provider) = top.executor {
            await provider.warmConnections(target: top.target(timeBudget: nil))
        }
        var probes: [DecisionAliasProbe] = []
        for planned in plan.ordered {
            guard case .provider(let provider) = planned.executor else { continue }
            let pinned = planned.candidate.binding.endpointModelId
            for alias in planned.candidate.entry.lifecycle.aliases {
                let status: DecisionAliasProbe.Status
                do {
                    if let served = try await provider.probeServedVersion(alias: alias, target: planned.target(timeBudget: nil)) {
                        status = served == pinned ? .matches : (served == alias ? .unverifiable : .drifted(servedVersion: served))
                    } else {
                        status = .unsupported
                    }
                } catch {
                    status = .failed(String(describing: error))
                }
                let probe = DecisionAliasProbe(
                    role: role, alias: alias, pinnedVersion: pinned, bindingID: planned.candidate.bindingID, status: status
                )
                log(probe)
                probes.append(probe)
            }
        }
        return probes
    }

    /// Keeps the top candidate's connection warm until cancelled, standing in for a TCP keepalive (which URLSession does
    /// not expose). The default interval stays under the common ~5 minute idle-close window. Run it in a task the host
    /// owns and cancel it at shutdown; it never probes aliases and never bills a decide call.
    public func keepWarm(role: ModelRole, interval: Duration = .seconds(240)) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            await warmTopCandidate(role: role)
        }
    }

    private func warmTopCandidate(role: ModelRole) async {
        guard let binding = roles.resolve(role), binding.contract == .decide else { return }
        let entries = await candidates.allContractEntries()
        let request = DecisionRequest(
            state: .string("ok"), questions: [DecisionQuestionItem("warm", .yesNo(instructions: .string("ok?")))]
        )
        guard case .success(let plan) = buildPlan(
            request: request, binding: binding, policy: nil, context: DecisionCallContext(), entries: entries
        ), let top = plan.ordered.first, case .provider(let provider) = top.executor else { return }
        await provider.warmConnections(target: top.target(timeBudget: nil))
    }

    /// Checks, without any network call, that `policy`'s bands cover a version the role's candidates serve, and
    /// logs what it finds. Run it when a threshold-bearing role is bound.
    @discardableResult
    public func validateBinding(role: ModelRole, policy: DecisionPolicy?) async -> DecisionBindingValidation {
        let tuned = (policy?.tunedVersions ?? []).sorted()
        guard let binding = roles.resolve(role), binding.contract == .decide else {
            logger.notice("decide role=\(role) is unbound; its consuming layer is off")
            return DecisionBindingValidation(role: role, servedVersions: [], tunedVersions: tuned, problems: [.roleUnbound])
        }
        let entries = await candidates.allContractEntries()
        let served = servedCandidates(binding: binding, policy: policy, entries: entries)
        let servedVersions = served.map(\.version).sorted()
        var problems: [DecisionBindingValidation.Problem] = []
        if served.isEmpty {
            problems.append(.noCandidates)
        }
        for candidate in served where candidate.entry.isAliasName(candidate.version, binding: candidate.binding) {
            problems.append(.movingAliasEndpoint(candidate.version))
        }
        if let policy, !policy.bands.isEmpty {
            for key in tuned {
                if let owner = served.first(where: { $0.entry.lifecycle.aliases.contains(key) }) {
                    problems.append(.bandsKeyedByAlias(alias: key, pinnedVersion: owner.version))
                } else if ModelLifecycle.looksLikeMovingAlias(key) {
                    problems.append(.bandsKeyedByAlias(alias: key, pinnedVersion: nil))
                }
            }
            let tunedSet = policy.tunedVersions
            if !served.isEmpty, !served.contains(where: { tunedSet.contains($0.version) }) {
                problems.append(.noTunedVersionServed(tuned: tuned, served: servedVersions))
            } else {
                let untuned = servedVersions.filter { !tunedSet.contains($0) }
                if !untuned.isEmpty { problems.append(.candidatesWithoutBands(untuned)) }
            }
        }
        let validation = DecisionBindingValidation(
            role: role, servedVersions: servedVersions, tunedVersions: tuned, problems: problems
        )
        log(validation, policy: policy)
        return validation
    }

    // MARK: - Planning

    enum Executor: Sendable {
        case provider(any DecisionProviding)
        case emulated(any DecisionEmulationLLMProviding, LLMEmulationDecisionCodec.Rung)
    }

    struct PlannedCandidate: Sendable {
        var candidate: ContractCandidate
        var executor: Executor
        var projected: CostProjection

        func target(timeBudget: Duration?) -> DecisionDispatchTarget {
            DecisionDispatchTarget(
                entry: candidate.entry, binding: candidate.binding, profile: candidate.profile, timeBudget: timeBudget
            )
        }
    }

    struct CandidatePlan: Sendable {
        var ordered: [PlannedCandidate]
        var rejected: [RouteReceipt.RankedOut]
    }

    nonisolated func buildPlan(
        request: DecisionRequest,
        binding: RoleBinding,
        policy: DecisionPolicy?,
        context: DecisionCallContext,
        entries: [ModelRegistryEntry]
    ) -> Result<CandidatePlan, DecisionDispatchError> {
        var rejected: [RouteReceipt.RankedOut] = []
        var ordered: [PlannedCandidate] = []
        var seen = Set<String>()
        func append(_ items: [PlannedCandidate]) {
            for item in items where seen.insert(item.candidate.bindingID).inserted {
                ordered.append(item)
            }
        }

        // Pin first; it must satisfy the contract and minGuarantee.
        if let pin = binding.pin {
            let matches = entries.filter { $0.isNamed(pin) }
            guard !matches.isEmpty else { return .failure(.pinRejected(pin: pin, reason: "not in registry")) }
            var planned: [PlannedCandidate] = []
            for match in matches { planned += evaluate(match, pinned: true, request: request, binding: binding, rejected: &rejected) }
            guard !planned.isEmpty else {
                let reason = rejected.last?.reason ?? "no serving binding"
                return .failure(.pinRejected(pin: pin, reason: reason))
            }
            append(planned)
        } else {
            var open: [PlannedCandidate] = []
            for entry in entries where entry.supports(.decide) { open += evaluate(entry, pinned: false, request: request, binding: binding, rejected: &rejected) }
            append(rank(open, role: binding.role, binding: binding, context: context))
        }
        for reference in binding.fallback {
            for entry in entries where entry.isNamed(reference) { append(evaluate(entry, pinned: true, request: request, binding: binding, rejected: &rejected)) }
        }

        // Compat-bound roles fall back only inside the primary's compat group.
        if binding.isCompatBound(policy: policy), let primary = ordered.first {
            let group = primary.candidate.entry.compatGroup
            ordered = ordered.enumerated().compactMap { index, item in
                if index == 0 || item.candidate.entry.id == primary.candidate.entry.id { return item }
                if let group, item.candidate.entry.compatGroup == group { return item }
                rejected.append(.init(modelID: item.candidate.entry.slug, reason: "outside compat group \(group ?? "none")"))
                return nil
            }
        }
        guard !ordered.isEmpty else {
            return .failure(.noCandidate(role: binding.role, localityRestricted: binding.locality != .any))
        }
        return .success(CandidatePlan(ordered: ordered, rejected: rejected))
    }

    nonisolated private func evaluate(
        _ entry: ModelRegistryEntry,
        pinned: Bool,
        request: DecisionRequest,
        binding: RoleBinding,
        rejected: inout [RouteReceipt.RankedOut]
    ) -> [PlannedCandidate] {
        let label = entry.slug
        if entry.lifecycle.status == .retired {
            rejected.append(.init(modelID: label, reason: "retired"))
            return []
        }
        if entry.lifecycle.status == .deprecated && !pinned {
            rejected.append(.init(modelID: label, reason: "deprecated (not pinned)"))
            return []
        }
        if !binding.locality.admits(entry.locality) {
            rejected.append(.init(modelID: label, reason: "locality \(binding.locality.rawValue)"))
            return []
        }
        if let family = entry.family, binding.query.excludeFamilies.contains(family) {
            rejected.append(.init(modelID: label, reason: "family \(family) excluded"))
            return []
        }
        var accepted: [PlannedCandidate] = []
        for providerBinding in entry.providers {
            guard let planned = plan(
                entry: entry, providerBinding: providerBinding, request: request, binding: binding,
                allowEmulation: pinned, rejected: &rejected
            ) else { continue }
            accepted.append(planned)
        }
        return accepted
    }

    nonisolated private func plan(
        entry: ModelRegistryEntry,
        providerBinding: ProviderBinding,
        request: DecisionRequest,
        binding: RoleBinding,
        allowEmulation: Bool,
        rejected: inout [RouteReceipt.RankedOut]
    ) -> PlannedCandidate? {
        let label = "\(providerBinding.providerId)/\(providerBinding.endpointModelId)"
        let estimatedTokens = DecisionCostEstimator.estimateInputTokens(characterCount: request.canonicalData.count)
        let prices = entry.effectivePrices(binding: providerBinding)
        let projected = DecisionCostEstimator.project(prices: prices, estimatedInputTokens: estimatedTokens)
        if let cap = binding.budget?.maxUSDPerCall, let usd = projected.usd, usd > cap {
            rejected.append(.init(modelID: label, reason: "projected $\(usd) over role cap $\(cap)"))
            return nil
        }

        if let profile = entry.profile(for: .decide, binding: providerBinding) {
            if let reason = filter(profile: profile, request: request, binding: binding) {
                rejected.append(.init(modelID: label, reason: reason))
                return nil
            }
            guard let provider = providers.decisionProvider(for: providerBinding) else {
                rejected.append(.init(modelID: label, reason: "no decision provider registered"))
                return nil
            }
            return PlannedCandidate(
                candidate: ContractCandidate(entry: entry, binding: providerBinding, profile: profile),
                executor: .provider(provider),
                projected: projected
            )
        }

        // Emulation over `generate` only when the model is named explicitly; the Pool never emulates silently.
        guard allowEmulation, let generate = entry.profile(for: .generate, binding: providerBinding) else {
            rejected.append(.init(modelID: label, reason: "no decide contract"))
            return nil
        }
        guard let emulator else {
            rejected.append(.init(modelID: label, reason: "no emulation provider"))
            return nil
        }
        let rung: LLMEmulationDecisionCodec.Rung = generate.feature("logprobs") != nil ? .logprobs : .schema
        let profile = ContractProfile(
            contract: .decide,
            surface: .llmEmulation,
            interaction: [.unary],
            input: [.text, .json],
            output: [.distribution],
            guarantee: rung.guarantee,
            features: [
                DecisionFeatureKey.questionTypes: FeatureSupport(
                    params: ["kinds": .array([.string("yes-no"), .string("choice"), .string("score")])]
                ),
            ],
            limits: ContractLimits(contextTokens: generate.limits.contextTokens, maxOptions: 255, scoreLevels: 2...10)
        )
        if let reason = filter(profile: profile, request: request, binding: binding) {
            rejected.append(.init(modelID: label, reason: reason))
            return nil
        }
        return PlannedCandidate(
            candidate: ContractCandidate(entry: entry, binding: providerBinding, profile: profile),
            executor: .emulated(emulator, rung),
            projected: DecisionCostEstimator.project(prices: prices, estimatedInputTokens: estimatedTokens)
        )
    }

    /// Hard filter: query facets, minGuarantee, question kinds, options, score levels, and image support.
    nonisolated private func filter(profile: ContractProfile, request: DecisionRequest, binding: RoleBinding) -> String? {
        var query = binding.query
        query.contract = .decide
        if let minGuarantee = binding.minGuarantee {
            query.minGuarantee = max(query.minGuarantee ?? minGuarantee, minGuarantee)
        }
        if let reason = query.rejection(for: profile) { return reason }
        if let reason = DecisionSurfaceOptions(profile: profile).rejection(for: request) { return reason }
        if let need = request.scoreLevelRange, let have = profile.limits.scoreLevels,
           need.lowerBound < have.lowerBound || need.upperBound > have.upperBound {
            return "score levels \(need) outside \(have)"
        }
        return nil
    }

    /// Rank by the role's explicit preferences, language fit, projected cost, observed latency, then binding priority.
    nonisolated private func rank(
        _ planned: [PlannedCandidate],
        role: ModelRole,
        binding: RoleBinding,
        context: DecisionCallContext
    ) -> [PlannedCandidate] {
        let prefer = binding.query.prefer
        func score(_ item: PlannedCandidate) -> Double {
            let entry = item.candidate.entry
            var score = 0.0
            if entry.roles.contains(role.rawValue) { score += 1000 }
            if prefer.roles.contains(where: entry.roles.contains) { score += 500 }
            if let useClass = prefer.useClass, entry.useClasses.contains(useClass) { score += 300 }
            if let family = prefer.family, entry.family == family { score += 200 }
            if let language = context.language?.lowercased() {
                let options = DecisionSurfaceOptions(profile: item.candidate.profile)
                if options.languagesStrong.contains(language) {
                    score += 150
                } else if options.languagesWeak.contains(language) {
                    score -= 150
                } else if !options.languagesStrong.isEmpty {
                    score -= 75
                }
            }
            if let usd = item.projected.usd {
                if let cap = prefer.maxProjectedUSD, usd > cap { score -= 400 }
                score -= min(100, usd * 10_000)
            } else {
                score -= 50
            }
            if let p50 = entry.performance?.p50LatencyMs {
                let budget = prefer.maxP50Ms ?? binding.budget?.maxLatencyMs
                if let budget, p50 > budget { score -= 300 }
                score -= min(100, p50 / 20)
            }
            return score
        }
        return planned.enumerated().sorted { lhs, rhs in
            let l = score(lhs.element)
            let r = score(rhs.element)
            if l != r { return l > r }
            if lhs.element.candidate.binding.priority != rhs.element.candidate.binding.priority {
                return lhs.element.candidate.binding.priority < rhs.element.candidate.binding.priority
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    nonisolated private func escalationCandidate(
        _ reference: String,
        request: DecisionRequest,
        binding: RoleBinding,
        entries: [ModelRegistryEntry]
    ) -> PlannedCandidate? {
        var ignored: [RouteReceipt.RankedOut] = []
        for entry in entries where entry.isNamed(reference) && entry.lifecycle.status != .retired {
            for providerBinding in entry.providers {
                if let planned = plan(
                    entry: entry, providerBinding: providerBinding, request: request, binding: binding,
                    allowEmulation: true, rejected: &ignored
                ) {
                    return planned
                }
            }
        }
        return nil
    }

    // MARK: - Dispatch

    struct StageResult: Sendable {
        var candidate: ContractCandidate
        var result: DecisionResult
        var costUSD: Double?
        var cacheHit: Bool
    }

    private func dispatch(
        _ request: DecisionRequest,
        over candidates: [PlannedCandidate],
        binding: RoleBinding,
        context: DecisionCallContext,
        receipt: inout RouteReceipt
    ) async -> Result<StageResult, DecisionDispatchError> {
        var lastError: DecisionDispatchError?
        for planned in candidates {
            let entry = planned.candidate.entry
            let wireID = planned.candidate.binding.endpointModelId
            let cacheVersion = entry.isAliasName(wireID, binding: planned.candidate.binding) ? nil : wireID
            if let cache, let cacheVersion, planned.candidate.profile.surface != .llmEmulation,
               let cached = await cache.lookup(modelVersion: cacheVersion, request: request) {
                return .success(StageResult(candidate: planned.candidate, result: cached, costUSD: 0, cacheHit: true))
            }

            do {
                try await budgetAccounting.authorize(
                    policy: budgetPolicy,
                    modelID: entry.id,
                    conversationID: context.conversationID,
                    accountID: context.accountID,
                    projectedCostUSD: planned.projected.usd
                )
            } catch {
                return .failure(.budgetDenied(String(describing: error)))
            }

            let acquisition = await scheduler.acquire(
                reservation: ModelCallReservation(
                    modelID: entry.id,
                    priority: binding.priority.requestPriority,
                    conversationID: context.conversationID,
                    ownerAccountID: context.accountID,
                    estimatedTotalTokens: DecisionCostEstimator.estimateInputTokens(
                        characterCount: request.canonicalData.count
                    )
                )
            )
            let outcome: Result<DecisionResult, Error>
            do {
                outcome = .success(try await execute(request, planned: planned, timeBudget: context.timeBudget))
            } catch {
                outcome = .failure(error)
            }
            await scheduler.release(acquisition: acquisition)

            switch outcome {
            case .success(let result):
                let prices = entry.effectivePrices(binding: planned.candidate.binding)
                let cost = planned.candidate.profile.surface == .llmEmulation
                    ? DecisionCostEstimator.settleEmulated(prices: prices, usage: result.usage)
                    : DecisionCostEstimator.settle(prices: prices, inputTokens: result.usage.inputTokens)
                await budgetAccounting.recordCompletion(
                    policy: budgetPolicy, modelID: entry.id, conversationID: context.conversationID,
                    accountID: context.accountID, actualCostUSD: cost
                )
                if let cache, let cacheVersion, result.calibrated,
                   !entry.isAliasName(result.modelVersion, binding: planned.candidate.binding) {
                    await cache.store(result, modelVersion: cacheVersion, request: request)
                }
                return .success(StageResult(candidate: planned.candidate, result: result, costUSD: cost, cacheHit: false))
            case .failure(let error):
                await budgetAccounting.recordCompletion(
                    policy: budgetPolicy, modelID: entry.id, conversationID: context.conversationID,
                    accountID: context.accountID, actualCostUSD: nil
                )
                let classification = classify(error, planned: planned)
                logger.warning("decide call failed on \(planned.candidate.bindingID): \(classification.rawValue)")
                lastError = .provider(classification: classification, message: String(describing: error))
                guard classification.isAvailabilityClass else { return .failure(lastError!) }
                receipt.fallback.append(.init(from: planned.candidate.bindingID, reason: classification))
            }
        }
        return .failure(lastError ?? .noCandidate(role: binding.role, localityRestricted: binding.locality != .any))
    }

    private func execute(
        _ request: DecisionRequest,
        planned: PlannedCandidate,
        timeBudget: Duration?
    ) async throws -> DecisionResult {
        switch planned.executor {
        case .provider(let provider):
            return try await provider.decide(request, target: planned.target(timeBudget: timeBudget))
        case .emulated(let emulator, let rung):
            let llm = try await emulator.emulationLLM(for: planned.candidate.entry)
            let codec = LLMEmulationDecisionCodec(
                llm: llm, rung: rung, modelVersion: planned.candidate.binding.endpointModelId
            )
            return try await codec.decide(request)
        }
    }

    private func classify(_ error: Error, planned: PlannedCandidate) -> ProviderFailoverClassification {
        switch planned.executor {
        case .provider(let provider): return provider.failoverError(error)
        case .emulated: return DefaultProviderFailoverClassifier.classify(error)
        }
    }

    private func apply(_ stage: StageResult, requested: [String], to receipt: inout RouteReceipt) {
        let candidate = stage.candidate
        receipt.resolved = RouteReceipt.Resolved(
            modelID: candidate.entry.slug,
            versionServed: stage.result.modelVersion,
            bindingID: candidate.bindingID,
            surface: candidate.profile.surface
        )
        if let alias = requested.first(where: { candidate.entry.lifecycle.aliases.contains($0) }) {
            receipt.aliasResolved = RouteReceipt.AliasResolution(alias: alias, to: candidate.binding.endpointModelId)
        } else if candidate.entry.lifecycle.aliasOf != nil {
            receipt.aliasResolved = RouteReceipt.AliasResolution(
                alias: candidate.binding.endpointModelId, to: stage.result.modelVersion
            )
        }
        receipt.guarantee = stage.result.guarantee
        receipt.costUSD = stage.costUSD
        receipt.requestIDs = stage.result.requestIDs
        receipt.cacheHit = stage.cacheHit
    }

    // MARK: - Router rank stage

    /// Rank stage, step 3: when a `router` is configured and the role is not pinned, let it move one candidate to the
    /// front. It is skipped for the router's own calls (no recursion) and when fewer than two candidates survive the
    /// hard filter, which for most `decide` roles is the common case.
    private func routerRanked(
        _ ordered: [PlannedCandidate],
        request: DecisionRequest,
        role: ModelRole,
        binding: RoleBinding,
        context: DecisionCallContext,
        receipt: inout RouteReceipt
    ) async -> [PlannedCandidate] {
        guard let router, role != router.configuration.role, binding.pin == nil, ordered.count >= 2 else { return ordered }
        let candidates = ordered.map { ModelPoolRouterCandidate.describing($0.candidate.entry, id: $0.candidate.bindingID) }
        guard let choice = await router.choose(
            request: Self.routerSummary(of: request, role: role),
            current: nil,
            candidates: candidates,
            dispatcher: self,
            context: context
        ), let index = ordered.firstIndex(where: { $0.candidate.bindingID == choice.id }) else { return ordered }
        receipt.routerPick = choice.id
        guard index > 0 else { return ordered }
        var reordered = ordered
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    /// What the router sees about a `decide` request: the role and its question kinds and instructions, not the state.
    static func routerSummary(of request: DecisionRequest, role: ModelRole) -> String {
        let questions = request.questions.map { "\($0.question.kind.rawValue): \(DecisionEntryText.text($0.question.instructions))" }
        return "decide role \(role.rawValue); questions: " + questions.joined(separator: " | ")
    }

    // MARK: - Version checks

    /// Evaluates `policy`, forcing an untuned verdict when the server answered as an alias (the version behind it
    /// is unknown, so no band can apply), and warns once per `(role, version)` whenever the answer is untuned.
    private func evaluate(_ stage: StageResult, policy: DecisionPolicy, role: ModelRole) -> DecisionEvaluation {
        let version = stage.result.modelVersion
        let tunedList = policy.tunedVersions.sorted()
        if stage.candidate.entry.isAliasName(version, binding: stage.candidate.binding) {
            warnUntunedOnce(role: role, version: version) {
                "decide role=\(role) was answered as alias \(version), so the version that answered is unknown; " +
                "policy is tuned for \(tunedList). Verdict forced to \(policy.onUnavailable.rawValue). " +
                "Pin a versioned endpoint id and list the alias under aliases."
            }
            return DecisionEvaluation(verdict: policy.onUnavailable.verdict, reason: .untunedVersion, modelVersion: version)
        }
        let evaluation = policy.evaluate(stage.result)
        if evaluation.reason == .untunedVersion {
            warnUntunedOnce(role: role, version: version) {
                "decide role=\(role) answered by \(version); policy is tuned for \(tunedList). " +
                "Verdict forced to \(policy.onUnavailable.rawValue)."
            }
        }
        return evaluation
    }

    private func warnUntunedOnce(role: ModelRole, version: String, _ message: () -> String) {
        guard warnedUntuned.insert("\(role.rawValue)/\(version)").inserted else { return }
        logger.warning("\(message())")
    }

    struct ServedCandidate: Sendable {
        var entry: ModelRegistryEntry
        var binding: ProviderBinding
        var version: String
    }

    /// Request-independent view of the bindings a role can dispatch to, including the escalation target.
    nonisolated func servedCandidates(
        binding: RoleBinding,
        policy: DecisionPolicy?,
        entries: [ModelRegistryEntry]
    ) -> [ServedCandidate] {
        let escalation = policy?.escalate?.to ?? binding.cascade?.to
        let named = [binding.pin].compactMap { $0 } + binding.fallback + [escalation].compactMap { $0 }
        var pool: [(entry: ModelRegistryEntry, named: Bool)] = []
        if binding.pin == nil {
            pool += entries.filter { $0.supports(.decide) }.map { ($0, false) }
        }
        for reference in named {
            pool += entries.filter { $0.isNamed(reference) }.map { ($0, true) }
        }
        var seen = Set<String>()
        var served: [ServedCandidate] = []
        for (entry, isNamed) in pool {
            guard entry.lifecycle.status != .retired,
                  entry.lifecycle.status != .deprecated || isNamed,
                  binding.locality.admits(entry.locality),
                  !(entry.family.map(binding.query.excludeFamilies.contains) ?? false)
            else { continue }
            for providerBinding in entry.providers {
                let decide = entry.profile(for: .decide, binding: providerBinding)
                let emulated = isNamed && decide == nil && emulator != nil
                    && entry.profile(for: .generate, binding: providerBinding) != nil
                guard decide != nil || emulated else { continue }
                if let decide {
                    var query = binding.query
                    query.contract = .decide
                    if let minGuarantee = binding.minGuarantee {
                        query.minGuarantee = max(query.minGuarantee ?? minGuarantee, minGuarantee)
                    }
                    guard query.rejection(for: decide) == nil else { continue }
                }
                let key = "\(providerBinding.providerId)/\(providerBinding.endpointModelId)"
                guard seen.insert(key).inserted else { continue }
                served.append(ServedCandidate(entry: entry, binding: providerBinding, version: providerBinding.endpointModelId))
            }
        }
        return served
    }

    static func requestedNames(_ binding: RoleBinding, policy: DecisionPolicy?) -> [String] {
        [binding.pin].compactMap { $0 } + binding.fallback + [policy?.escalate?.to ?? binding.cascade?.to].compactMap { $0 }
    }

    private func log(_ validation: DecisionBindingValidation, policy: DecisionPolicy?) {
        let role = validation.role
        for problem in validation.problems {
            switch problem {
            case .roleUnbound:
                logger.notice("decide role=\(role) is unbound; its consuming layer is off")
            case .noCandidates:
                logger.error("decide role=\(role) is bound but no registry entry can serve it; every call will fail conservatively")
            case .noTunedVersionServed(let tuned, let served):
                let fallback = policy?.onUnavailable.rawValue ?? "onUnavailable"
                logger.error(
                    "decide role=\(role) will never act: policy is tuned for \(tuned) but its candidates serve \(served); every verdict resolves to \(fallback)"
                )
            case .candidatesWithoutBands(let versions):
                logger.warning("decide role=\(role): candidates \(versions) have no policy bands and will answer as untuned")
            case .bandsKeyedByAlias(let alias, let pinned):
                let hint = pinned.map { "key them by the pinned version \($0)" } ?? "key them by a pinned version"
                logger.warning("decide role=\(role): policy bands are keyed by moving alias \(alias) and will never match; \(hint)")
            case .movingAliasEndpoint(let id):
                logger.warning(
                    "decide role=\(role): candidate is addressed by moving alias \(id); pin the versioned id as endpointModelID and list \(id) under aliases"
                )
            }
        }
    }

    private func log(_ probe: DecisionAliasProbe) {
        switch probe.status {
        case .matches:
            logger.debug("decide role=\(probe.role): alias \(probe.alias) still serves pinned \(probe.pinnedVersion)")
        case .drifted(let served):
            logger.warning(
                "decide role=\(probe.role): alias \(probe.alias) now serves \(served) but \(probe.bindingID) is pinned to \(probe.pinnedVersion); keep the pin, or re-tune the policy for \(served) and update the pin"
            )
        case .unverifiable:
            logger.warning(
                "decide role=\(probe.role): server echoed alias \(probe.alias) instead of a version; cannot confirm it still serves \(probe.pinnedVersion)"
            )
        case .failed(let message):
            logger.warning("decide role=\(probe.role): alias probe for \(probe.alias) failed: \(message)")
        case .unsupported:
            logger.debug("decide role=\(probe.role): \(probe.bindingID) cannot probe alias \(probe.alias)")
        }
    }

    // MARK: - Helpers

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    static func sum(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a + b
    }

    static func describe(_ condition: DeferralCondition) -> String {
        switch condition {
        case .pBelow(let value, _): return "p < \(value)"
        case .marginBelow(let value, _): return "margin < \(value)"
        case .pBetween(let low, let high, _): return "p in [\(low), \(high)]"
        case .spreadAbove(let value, _): return "spread > \(value)"
        case .refused: return "refused"
        case .unavailable: return "unavailable"
        case .any(let conditions): return "any(" + conditions.map(describe).joined(separator: ", ") + ")"
        case .all(let conditions): return "all(" + conditions.map(describe).joined(separator: ", ") + ")"
        }
    }
}
