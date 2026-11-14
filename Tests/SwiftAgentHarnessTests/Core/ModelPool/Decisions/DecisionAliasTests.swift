import EasyJSON
import Foundation
import Logging
import Synchronization
import Testing
@testable import SwiftAgentHarness

// MARK: - Support

/// Captures log lines for assertions. `Mutex` provides the synchronization, so the class is `Sendable` as declared.
final class DecisionLogCapture: Sendable {
    struct Entry: Sendable {
        var level: Logger.Level
        var message: String
    }

    private let storage = Mutex<[Entry]>([])

    var logger: Logger {
        Logger(label: "decision-test") { _ in DecisionCaptureHandler(capture: self) }
    }

    func append(_ entry: Entry) {
        storage.withLock { $0.append(entry) }
    }

    func messages(atLeast level: Logger.Level) -> [String] {
        storage.withLock { entries in entries.filter { $0.level >= level }.map(\.message) }
    }
}

private struct DecisionCaptureHandler: LogHandler {
    let capture: DecisionLogCapture
    var metadata: Logger.Metadata = [:]
    var logLevel: Logger.Level = .trace

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        capture.append(.init(level: level, message: message.description))
    }
}

/// A vendor that answers `model` the way TypeSafe documents it: `jev-latest` and the pinned version both answer as
/// `servedVersion`, unless `echoAlias` is set.
private func vendorTransport(servedVersion: String = "jev-1.13.0", pYes: Double = 0.99, echoAlias: Bool = false) -> MockDecisionTransport {
    MockDecisionTransport(handler: { request in
        if request.httpMethod == "GET" { return .ok("{\"data\": []}") }
        let requested = request.jsonBody?[test: "model"]?.testString ?? ""
        let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
        let answers = ids.map { "\"\($0)\": {\"type\": \"noul\", \"noul\": \(pYes)}" }.joined(separator: ",")
        let model = echoAlias && requested.hasSuffix("-latest") ? requested : servedVersion
        return .ok("{\"model\": \"\(model)\", \"answers\": {\(answers)}, \"usage\": {\"input_tokens\": 40}}")
    })
}

private func runtime(
    endpointModelID: String = "jev-1.13.0",
    aliases: [String] = ["jev-latest"],
    serverURL: String = "https://api.typesafe.example/v1",
    profile: ContractProfile? = nil
) -> DecisionRuntimeConfig {
    DecisionRuntimeConfig(
        providerID: "systemone",
        label: "SystemOne",
        surface: .systemOne,
        serverURL: URL(string: serverURL)!,
        models: [DecisionModelConfig(endpointModelID: endpointModelID, aliases: aliases, profile: profile, roles: ["gatekeeper"])]
    )
}

private func pool(
    _ config: DecisionRuntimeConfig,
    transport: MockDecisionTransport,
    binding: RoleBinding = RoleBinding(role: .gatekeeper, contract: .decide),
    logs: DecisionLogCapture = DecisionLogCapture(),
    cache: DecisionResponseCache? = nil,
    extraEntries: [ModelRegistryEntry] = []
) -> ModelPoolDecisionDispatcher {
    let provider = config.makeProvider(transport: transport, retryExecutor: instantRetryExecutor())
    return ModelPoolDecisionDispatcher(
        candidates: StaticContractCandidateSource(config.registryEntries() + extraEntries),
        providers: StaticDecisionProviderResolver([config.providerID: provider]),
        roles: RoleBindingResolver(settings: [binding.role: binding]),
        cache: cache,
        logger: logs.logger
    )
}

private func bands(_ versions: String...) -> DecisionPolicy {
    DecisionFixtures.gatePolicy(versions: versions)
}

// MARK: - Configuration

@Suite("Decision runtime aliases and API root")
struct DecisionRuntimeAliasConfigTests {
    @Test("Aliases are recorded on the entry's lifecycle; the wire id stays the pinned version")
    func aliasesOnLifecycle() {
        let entry = runtime().registryEntries()[0]
        #expect(entry.lifecycle.aliases == ["jev-latest"])
        #expect(entry.providers[0].endpointModelId == "jev-1.13.0")
        #expect(entry.isNamed("jev-latest"))
        #expect(entry.isNamed("jev-1.13.0"))
        #expect(!entry.isNamed("jev-preview"))
        let duplicate = runtime(aliases: ["jev-1.13.0", "jev-latest", "jev-latest"]).registryEntries()[0]
        #expect(duplicate.lifecycle.aliases == ["jev-latest"])
    }

    @Test("Moving-alias naming patterns")
    func movingAliasPattern() {
        #expect(ModelLifecycle.looksLikeMovingAlias("jev-latest"))
        #expect(ModelLifecycle.looksLikeMovingAlias("JEV-Preview"))
        #expect(ModelLifecycle.looksLikeMovingAlias("latest"))
        #expect(!ModelLifecycle.looksLikeMovingAlias("jev-1.13.0"))
        #expect(!ModelLifecycle.looksLikeMovingAlias("latest-model-2"))
    }

    @Test("Lifecycle decodes rows written before aliases existed")
    func lifecycleDecodesLegacy() throws {
        let decoded = try JSONDecoder().decode(ModelLifecycle.self, from: Data(#"{"status": "active", "aliasOf": "x"}"#.utf8))
        #expect(decoded.aliases.isEmpty)
        #expect(decoded.aliasOf == "x")
        let roundTrip = try JSONDecoder().decode(ModelLifecycle.self, from: JSONEncoder().encode(ModelLifecycle(aliases: ["a"])))
        #expect(roundTrip.aliases == ["a"])
    }

    @Test("serverURL is trimmed to the API root when it already names the surface's endpoint")
    func apiRootTrimming() {
        let cases: [(String, ContractSurface, String)] = [
            ("https://api.typesafe.example", .systemOne, "https://api.typesafe.example"),
            ("https://api.typesafe.example/v1", .systemOne, "https://api.typesafe.example/v1"),
            ("https://api.typesafe.example/v1/systemone", .systemOne, "https://api.typesafe.example/"),
            ("https://api.typesafe.example/v1/systemone/", .systemOne, "https://api.typesafe.example/"),
            ("https://edge.example/client/v4/v1/systemone", .systemOne, "https://edge.example/client/v4/"),
            ("https://api.openai.com/v1/decisions", .openAIDecisions, "https://api.openai.com/"),
            ("https://api.openai.com/v1/decisions", .systemOne, "https://api.openai.com/v1/decisions"),
        ]
        for (input, surface, expected) in cases {
            #expect(DecisionRuntimeConfig.apiRoot(for: URL(string: input)!, surface: surface).absoluteString == expected, "\(input)")
        }
        let config = runtime(serverURL: "https://api.typesafe.example/v1/systemone")
        #expect(config.serverURL.absoluteString == "https://api.typesafe.example/")
        #expect(config.manifest().defaultEndpoint?.baseURL.absoluteString == "https://api.typesafe.example/")
    }

    @Test("A serverURL reassigned after init is still trimmed where it is used")
    func reassignedServerURL() {
        var config = runtime()
        config.serverURL = URL(string: "https://api.typesafe.example/v1/systemone")!
        #expect(config.registryEntries()[0].providers[0].serverURL.absoluteString == "https://api.typesafe.example/")
    }

    @Test("Endpoint joining leaves a base that already ends in the path unchanged")
    func endpointJoinIdempotent() {
        let base = URL(string: "https://api.typesafe.example/v1/systemone")!
        #expect(DecisionEndpoint.url(base: base, path: "v1/systemone").absoluteString == "https://api.typesafe.example/v1/systemone")
    }

    @Test("A pasted full endpoint URL sends decide and warm-up calls to the right paths")
    func pastedEndpointURL() async throws {
        let transport = vendorTransport()
        let config = runtime(serverURL: "https://api.typesafe.example/v1/systemone")
        let dispatcher = pool(config, transport: transport)
        let outcome = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: bands("jev-1.13.0"))
        #expect(outcome.verdict == .act)
        _ = await dispatcher.warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        let urls = await transport.requests.compactMap { $0.url?.absoluteString }
        #expect(urls.first == "https://api.typesafe.example/v1/systemone")
        #expect(urls.contains("https://api.typesafe.example/v1/models"))
        #expect(!urls.contains { $0.contains("systemone/v1") })
    }
}

// MARK: - Dispatch

@Suite("Decision alias resolution and untuned answers")
struct DecisionAliasDispatchTests {
    @Test("Pinning the vendor alias selects the pinned version, sends it on the wire, and records both")
    func aliasPin() async throws {
        let transport = vendorTransport()
        let dispatcher = pool(runtime(), transport: transport, binding: RoleBinding(role: .gatekeeper, contract: .decide, pin: "jev-latest"))
        let outcome = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: bands("jev-1.13.0"))
        #expect(outcome.verdict == .act)
        #expect(outcome.receipt.aliasResolved == RouteReceipt.AliasResolution(alias: "jev-latest", to: "jev-1.13.0"))
        #expect(outcome.receipt.resolved?.versionServed == "jev-1.13.0")
        #expect(await transport.requests.first?.jsonBody?[test: "model"]?.testString == "jev-1.13.0")
    }

    @Test("The reported setup (alias as the endpoint id, bands under the alias) never acts and warns once naming both versions")
    func reportedScenario() async {
        let logs = DecisionLogCapture()
        let dispatcher = pool(runtime(endpointModelID: "jev-latest", aliases: []), transport: vendorTransport(), logs: logs)
        let policy = bands("jev-latest")
        let first = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: policy)
        _ = await dispatcher.decide(DecisionFixtures.yesNoRequest(["safe"], state: .string("other")), role: .gatekeeper, policy: policy)
        #expect(first.verdict == .confirm)
        #expect(first.evaluation?.reason == .untunedVersion)
        let warnings = logs.messages(atLeast: .warning).filter { $0.contains("answered by jev-1.13.0") }
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("[\"jev-latest\"]") == true)
        #expect(warnings.first?.contains("confirm") == true)
    }

    @Test("A response that echoes an alias is treated as untuned, even when bands exist under that alias")
    func aliasEchoIsUntuned() async {
        let logs = DecisionLogCapture()
        let echoed = DecisionResult(
            modelVersion: "jev-latest", calibrated: true, guarantee: .calibratedDistribution, answers: ["safe": .yesNo(pYes: 0.99)]
        )
        let echoing = FakeDecisionProvider(providerID: "systemone") { _, _ in echoed }
        let echoPool = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource(runtime().registryEntries()),
            providers: StaticDecisionProviderResolver(["systemone": echoing]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            logger: logs.logger
        )
        let outcome = await echoPool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: bands("jev-1.13.0", "jev-latest"))
        #expect(outcome.verdict == .confirm)
        #expect(outcome.evaluation?.reason == .untunedVersion)
        #expect(logs.messages(atLeast: .warning).contains { $0.contains("answered as alias jev-latest") })
    }

    @Test("An undeclared *-preview id echoed back is untuned too")
    func movingAliasPatternEcho() async {
        let echoing = FakeDecisionProvider.constant(providerID: "systemone", pYes: 0.99, version: "jev-preview")
        let entries = runtime(endpointModelID: "jev-preview", aliases: []).registryEntries()
        let echoPool = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource(entries),
            providers: StaticDecisionProviderResolver(["systemone": echoing]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            logger: DecisionLogCapture().logger
        )
        let outcome = await echoPool.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: bands("jev-preview"))
        #expect(outcome.verdict == .confirm)
        #expect(outcome.evaluation?.reason == .untunedVersion)
    }

    @Test("Untuned warnings are per (role, version): a second version warns again")
    func warnOncePerVersion() async {
        let logs = DecisionLogCapture()
        let versions = VersionSequence(["jev-1.13.0", "jev-1.13.0", "jev-1.14.0"])
        let provider = FakeDecisionProvider(providerID: "systemone") { request, _ in
            DecisionResult(
                modelVersion: await versions.next(), calibrated: true, guarantee: .calibratedDistribution,
                answers: ["safe": .yesNo(pYes: 0.99)]
            )
        }
        let dispatcher = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource(runtime().registryEntries()),
            providers: StaticDecisionProviderResolver(["systemone": provider]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            logger: logs.logger
        )
        for _ in 0..<3 {
            _ = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper, policy: bands("jev-1.12.0"))
        }
        let warnings = logs.messages(atLeast: .warning).filter { $0.contains("policy is tuned for") }
        #expect(warnings.count == 2)
    }

    @Test("Alias-addressed answers are never response-cached")
    func noCachingOnAlias() async {
        let transport = vendorTransport()
        let dispatcher = pool(runtime(endpointModelID: "jev-latest", aliases: []), transport: transport, cache: DecisionResponseCache())
        _ = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        let second = await dispatcher.decide(DecisionFixtures.yesNoRequest(), role: .gatekeeper)
        #expect(!second.receipt.cacheHit)
        #expect(await transport.requestCount == 2)
    }
}

/// Hands out versions in order, repeating the last.
private actor VersionSequence {
    private var versions: [String]

    init(_ versions: [String]) {
        self.versions = versions
    }

    func next() -> String {
        versions.count > 1 ? versions.removeFirst() : versions[0]
    }
}

// MARK: - Load-time validation and drift

@Suite("Decision binding validation and alias drift")
struct DecisionBindingValidationTests {
    @Test("Bands keyed by an alias of the served version: an error that the role will never act, with the fix named")
    func bandsUnderAlias() async {
        let logs = DecisionLogCapture()
        let dispatcher = pool(runtime(), transport: vendorTransport(), logs: logs)
        let validation = await dispatcher.validateBinding(role: .gatekeeper, policy: bands("jev-latest"))
        #expect(!validation.canAct)
        #expect(validation.servedVersions == ["jev-1.13.0"])
        #expect(validation.problems.contains(.noTunedVersionServed(tuned: ["jev-latest"], served: ["jev-1.13.0"])))
        #expect(validation.problems.contains(.bandsKeyedByAlias(alias: "jev-latest", pinnedVersion: "jev-1.13.0")))
        let errors = logs.messages(atLeast: .error)
        #expect(errors.contains { $0.contains("decide role=gatekeeper will never act") && $0.contains("confirm") })
        #expect(logs.messages(atLeast: .warning).contains { $0.contains("key them by the pinned version jev-1.13.0") })
    }

    @Test("A correctly pinned binding validates clean")
    func clean() async {
        let logs = DecisionLogCapture()
        let validation = await pool(runtime(), transport: vendorTransport(), logs: logs)
            .validateBinding(role: .gatekeeper, policy: bands("jev-1.13.0"))
        #expect(validation.canAct)
        #expect(validation.problems.isEmpty)
        #expect(logs.messages(atLeast: .warning).isEmpty)
    }

    @Test("An alias used as the endpoint id is flagged even when the bands match it")
    func movingAliasEndpoint() async {
        let validation = await pool(runtime(endpointModelID: "jev-latest", aliases: []), transport: vendorTransport(), logs: DecisionLogCapture())
            .validateBinding(role: .gatekeeper, policy: bands("jev-latest"))
        #expect(validation.problems.contains(.movingAliasEndpoint("jev-latest")))
        #expect(validation.problems.contains(.bandsKeyedByAlias(alias: "jev-latest", pinnedVersion: nil)))
    }

    @Test("Fallbacks and the escalation target without bands are reported as untuned candidates")
    func partialCoverage() async {
        let fallback = DecisionFixtures.decider("jev-1.12.0", provider: "systemone", compatGroup: nil)
        let big = DecisionFixtures.decider("jev-xl-2.0", provider: "systemone", compatGroup: nil)
        var policy = bands("jev-1.13.0")
        policy.escalate = DecisionEscalation(to: "jev-xl-2.0", when: .pBelow(0.9))
        let dispatcher = pool(
            runtime(), transport: vendorTransport(),
            binding: RoleBinding(role: .gatekeeper, contract: .decide, pin: "jev-latest", fallback: ["jev-1.12.0"]),
            extraEntries: [fallback, big]
        )
        let validation = await dispatcher.validateBinding(role: .gatekeeper, policy: policy)
        #expect(validation.servedVersions == ["jev-1.12.0", "jev-1.13.0", "jev-xl-2.0"])
        #expect(validation.problems == [.candidatesWithoutBands(["jev-1.12.0", "jev-xl-2.0"])])
        #expect(validation.canAct)
    }

    @Test("Unbound roles and roles with no serving entry are reported")
    func unboundAndEmpty() async {
        let unbound = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([]), roles: RoleBindingResolver(), logger: DecisionLogCapture().logger
        )
        #expect(await unbound.validateBinding(role: .gatekeeper, policy: bands("v")).problems == [.roleUnbound])
        let empty = ModelPoolDecisionDispatcher(
            candidates: StaticContractCandidateSource([]),
            roles: RoleBindingResolver(settings: [.gatekeeper: RoleBinding(role: .gatekeeper, contract: .decide)]),
            logger: DecisionLogCapture().logger
        )
        #expect(await empty.validateBinding(role: .gatekeeper, policy: bands("v")).problems == [.noCandidates])
    }

    @Test("Policies without bands are not threshold-bearing and skip the overlap check")
    func noBands() async {
        let validation = await pool(runtime(), transport: vendorTransport(), logs: DecisionLogCapture())
            .validateBinding(role: .gatekeeper, policy: DecisionPolicy(question: "safe", bands: [:]))
        #expect(validation.problems.isEmpty)
    }

    @Test("Warm-up probes the alias on the wire and warns when it has moved to a new version")
    func driftDetected() async {
        let logs = DecisionLogCapture()
        let transport = vendorTransport(servedVersion: "jev-1.14.0")
        let probes = await pool(runtime(), transport: transport, logs: logs)
            .warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(probes == [DecisionAliasProbe(
            role: .gatekeeper, alias: "jev-latest", pinnedVersion: "jev-1.13.0",
            bindingID: "systemone/jev-1.13.0", status: .drifted(servedVersion: "jev-1.14.0")
        )])
        let posts = await transport.requests.filter { $0.httpMethod == "POST" }
        #expect(posts.compactMap { $0.jsonBody?[test: "model"]?.testString } == ["jev-latest"])
        #expect(logs.messages(atLeast: .warning).contains {
            $0.contains("alias jev-latest now serves jev-1.14.0") && $0.contains("pinned to jev-1.13.0")
        })
    }

    @Test("Warm-up reports matches, echoed aliases, unsupported servers, and failures")
    func probeOutcomes() async {
        let matching = await pool(runtime(), transport: vendorTransport()).warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(matching.map(\.status) == [.matches])

        let echoLogs = DecisionLogCapture()
        let echoing = await pool(runtime(), transport: vendorTransport(echoAlias: true), logs: echoLogs)
            .warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(echoing.map(\.status) == [.unverifiable])
        #expect(echoLogs.messages(atLeast: .warning).contains { $0.contains("echoed alias jev-latest") })

        let omitModel = DecisionProfiles.systemOne(extraFeatures: [
            DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")]),
        ])
        let unsupported = await pool(runtime(profile: omitModel), transport: vendorTransport())
            .warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(unsupported.map(\.status) == [.unsupported])

        let failing = MockDecisionTransport(handler: { request in
            request.httpMethod == "GET" ? .ok("{}") : .status(401, "{\"error\": \"bad key\"}")
        })
        let failed = await pool(runtime(), transport: failing).warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        guard case .failed? = failed.first?.status else {
            Issue.record("expected a failed probe, got \(failed)")
            return
        }
    }

    @Test("Entries without aliases are not probed")
    func noAliasesNoProbe() async {
        let transport = vendorTransport()
        let probes = await pool(runtime(aliases: []), transport: transport).warm(role: .gatekeeper, request: DecisionFixtures.yesNoRequest())
        #expect(probes.isEmpty)
        #expect(await transport.requests.allSatisfy { $0.httpMethod == "GET" })
    }
}

// MARK: - Gate

@Suite("Classifier gate alias diagnostics")
struct ClassifierGateAliasTests {
    private func gate(_ config: DecisionRuntimeConfig, policyVersions: [String], transport: MockDecisionTransport, logs: DecisionLogCapture) -> ToolApprovalClassifierGate {
        let dispatcher = pool(config, transport: transport, logs: logs)
        return ToolApprovalClassifierGate(
            dispatcher: dispatcher,
            configuration: ToolApprovalClassifierConfiguration(policy: DecisionFixtures.gatePolicy(
                versions: policyVersions, question: ToolApprovalClassifierConfiguration.questionID
            ))
        )
    }

    @Test("The first evaluation validates the binding once and logs that the gate can never act")
    func validatesOnFirstUse() async {
        let logs = DecisionLogCapture()
        let classifier = gate(runtime(), policyVersions: ["jev-latest"], transport: choiceTransport(), logs: logs)
        _ = await classifier.evaluate(GatekeeperFixtures.input())
        _ = await classifier.evaluate(GatekeeperFixtures.input())
        let validation = await classifier.validation
        #expect(validation?.canAct == false)
        #expect(logs.messages(atLeast: .error).filter { $0.contains("will never act") }.count == 1)
    }

    @Test("An untuned answer asks with untunedVersion, and prepare() reports drift")
    func untunedReasonAndPrepare() async {
        let logs = DecisionLogCapture()
        let classifier = gate(runtime(), policyVersions: ["jev-1.12.0"], transport: choiceTransport(servedVersion: "jev-1.13.0"), logs: logs)
        guard case .ask(let reason, _) = await classifier.evaluate(GatekeeperFixtures.input()) else {
            Issue.record("expected ask")
            return
        }
        #expect(reason == .untunedVersion)

        let driftLogs = DecisionLogCapture()
        let drifting = gate(runtime(), policyVersions: ["jev-1.13.0"], transport: choiceTransport(aliasServes: "jev-1.14.0"), logs: driftLogs)
        let prepared = await drifting.prepare()
        #expect(prepared.validation.canAct)
        #expect(prepared.aliasProbes.map(\.status) == [.drifted(servedVersion: "jev-1.14.0")])
        guard case .allowOnce = await drifting.evaluate(GatekeeperFixtures.input()) else {
            Issue.record("the pinned version keeps acting after the alias moves")
            return
        }
    }

    /// Answers the gate's `verdict` choice with P(clear) = 0.99. The alias may answer as a different version.
    private func choiceTransport(servedVersion: String = "jev-1.13.0", aliasServes: String? = nil) -> MockDecisionTransport {
        MockDecisionTransport(handler: { request in
            if request.httpMethod == "GET" { return .ok("{}") }
            let requested = request.jsonBody?[test: "model"]?.testString ?? ""
            let model = requested == "jev-latest" ? (aliasServes ?? servedVersion) : servedVersion
            let ids = request.jsonBody?[test: "questions"]?.testObject?.keys.sorted() ?? []
            let answers = ids.map { id in
                id == ToolApprovalClassifierConfiguration.questionID
                    ? "\"\(id)\": {\"type\": \"choice\", \"choice\": \"clear\", \"probabilities\": {\"clear\": 0.99, \"caution\": 0.01}}"
                    : "\"\(id)\": {\"type\": \"noul\", \"noul\": 0.9}"
            }.joined(separator: ",")
            return .ok("{\"model\": \"\(model)\", \"answers\": {\(answers)}}")
        })
    }
}
