#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import EasyJSON
import Foundation
import SwiftAgentKit
import Testing
@testable import SwiftAgentHarness

private let choiceRequest = DecisionRequest(
    state: .string("User asked to refactor the parser."),
    questions: [
        DecisionQuestionItem("skill", .choice(instructions: .string("Which skill applies?"), options: [
            DecisionOption("refactor"), DecisionOption("test"), DecisionOption("docs"),
        ])),
    ]
)

@Suite("LLM emulation codec")
struct LLMEmulationDecisionCodecTests {
    @Test("Schema rung returns labels as advisory metadata, never a probability")
    func schemaRung() async throws {
        let llm = ScriptedDecisionLLM(responses: [
            LLMResponse(content: "{\"safe\": \"yes\", \"skill\": \"test\"}", metadata: LLMMetadata(promptTokens: 80, completionTokens: 12)),
        ])
        var request = choiceRequest
        request.questions.insert(DecisionQuestionItem("safe", .yesNo(instructions: .string("Is it safe?"))), at: 0)
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .schema).decide(request)
        #expect(!result.calibrated)
        #expect(result.guarantee == .schemaStrict)
        #expect(result.modelVersion == "chat-emulator-1")
        #expect(result.answers["safe"] == .unavailable(reason: .emulatedNoProbability, advisoryLabel: "yes"))
        #expect(result.answers["skill"] == .unavailable(reason: .emulatedNoProbability, advisoryLabel: "test"))
        #expect(result.usage.inputTokens == 80)

        let config = try #require(await llm.configs.first)
        guard case .jsonSchema(let name, let schema) = config.responseFormat else {
            Issue.record("expected a strict JSON schema response format")
            return
        }
        #expect(name == "decision_answers")
        #expect(schema[test: "properties"]?[test: "skill"]?[test: "enum"]?.testArray?.count == 3)
        #expect(config.reasoningEffort == nil)
        #expect(config.temperature == 0)
    }

    @Test("Schema rung tolerates fenced JSON and marks unknown labels and missing ids")
    func schemaRungParsing() async throws {
        let llm = ScriptedDecisionLLM(responses: [LLMResponse(content: "```json\n{\"skill\": \"nope\"}\n```")])
        var request = choiceRequest
        request.questions.append(DecisionQuestionItem("other", .yesNo(instructions: .string("?"))))
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .schema).decide(request)
        #expect(result.answers["skill"] == .unavailable(reason: .emulatedNoProbability, advisoryLabel: nil))
        #expect(result.answers["other"] == .unavailable(reason: .missingInResponse))
    }

    @Test("Logprobs rung renormalizes top logprobs over the legal tokens")
    func logprobsChoice() async throws {
        let llm = ScriptedDecisionLLM(responses: [
            ScriptedDecisionLLM.logprobs([("A", 0.6), ("B", 0.2), (" C", 0.1), ("Sure", 0.1)]),
        ])
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .logprobs, modelVersion: "chat-1@2026-09").decide(choiceRequest)
        #expect(!result.calibrated)
        #expect(result.guarantee == .logprobs)
        #expect(result.modelVersion == "chat-1@2026-09")
        guard case .choice(let choice, let probabilities) = result.answers["skill"] else {
            Issue.record("expected a choice distribution")
            return
        }
        #expect(choice == "refactor")
        #expect(abs(probabilities["refactor"]! - 0.6 / 0.9) < 1e-9)
        #expect(abs(probabilities["docs"]! - 0.1 / 0.9) < 1e-9)
        let config = try #require(await llm.configs.first)
        #expect(config.maxTokens == 1)
        #expect(config.additionalParameters?[test: "top_logprobs"]?.testNumber == 20)
    }

    @Test("Logprobs rung answers yes-no and score questions one call each")
    func logprobsYesNoAndScore() async throws {
        let llm = ScriptedDecisionLLM(responses: [
            ScriptedDecisionLLM.logprobs([("Y", 0.75), ("N", 0.25)]),
            ScriptedDecisionLLM.logprobs([("0", 0.1), ("1", 0.3), ("2", 0.6)]),
        ])
        let request = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("ok", .yesNo(instructions: .string("ok?"))),
            DecisionQuestionItem("sev", .score(instructions: .string("severity"), levels: [.string("low"), .string("mid"), .string("high")])),
        ])
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .logprobs).decide(request)
        #expect(await llm.callCount == 2)
        guard case .yesNo(let pYes) = result.answers["ok"] else { Issue.record("expected yes-no"); return }
        #expect(abs(pYes - 0.75) < 1e-9)
        guard case .score(let expected, let probabilities) = result.answers["sev"] else { Issue.record("expected score"); return }
        #expect(abs(expected - 1.5) < 1e-9)
        #expect(probabilities.count == 3)
    }

    @Test("Without logprobs metadata the answer is unavailable with an advisory label")
    func logprobsMissing() async throws {
        let llm = ScriptedDecisionLLM(responses: [LLMResponse(content: "B")])
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .logprobs).decide(choiceRequest)
        #expect(result.answers["skill"] == .unavailable(reason: .emulatedNoProbability, advisoryLabel: "test"))
    }

    @Test("Box questions cannot be emulated and make no call")
    func boxNotEmulated() async throws {
        let llm = ScriptedDecisionLLM(responses: [])
        let request = DecisionRequest(
            state: .string("s"),
            assets: ["a": DecisionImageAsset(mediaType: .png, data: Data([1]))],
            questions: [DecisionQuestionItem("b", .box(instructions: .string("find")))]
        )
        let result = try await LLMEmulationDecisionCodec(llm: llm, rung: .logprobs).decide(request)
        #expect(result.answers["b"] == .unavailable(reason: .emulatedNoProbability))
        #expect(await llm.callCount == 0)
    }

    @Test("Legal tokens per kind")
    func tokens() {
        #expect(LLMEmulationDecisionCodec.tokens(for: .yesNo(instructions: .string("?"))) == ["Y", "N"])
        #expect(LLMEmulationDecisionCodec.tokens(for: choiceRequest.questions[0].question) == ["A", "B", "C"])
        let many = DecisionQuestion.choice(instructions: .string("?"), options: (0..<27).map { DecisionOption("o\($0)") })
        #expect(LLMEmulationDecisionCodec.tokens(for: many) == nil)
    }
}

@Suite("Decision image normalizer")
struct DecisionImageNormalizerTests {
    let window = DecisionImageNormalizer.Window(edgePx: 280...1568, totalPixels: 78_400...2_458_624)

    @Test("Scale factors bring images inside the edge and pixel window")
    func scales() {
        #expect(DecisionImageNormalizer.scale(width: 800, height: 600, window: window) == 1)
        let down = DecisionImageNormalizer.scale(width: 4000, height: 3000, window: window)!
        #expect(4000 * down <= 1568.0001)
        let up = DecisionImageNormalizer.scale(width: 200, height: 200, window: window)!
        #expect(200 * up >= 279.999)
        #expect(DecisionImageNormalizer.scale(width: 10_000, height: 10, window: window) == nil)
        #expect(DecisionImageNormalizer.scale(width: 0, height: 10, window: window) == nil)
    }

    #if canImport(ImageIO)
    @Test("Oversized images are re-encoded inside the window")
    func resizes() throws {
        let png = try Self.makePNG(width: 3000, height: 2000)
        let normalized = try DecisionImageNormalizer.normalize(DecisionImageAsset(mediaType: .png, data: png), window: window)
        let size = try #require(DecisionImageNormalizer.dimensions(of: normalized.data))
        #expect(max(size.width, size.height) <= 1568)
        #expect(size.width * size.height <= 2_458_624)
        #expect(normalized.mediaType == .png)
    }

    @Test("In-window images pass through untouched")
    func passthrough() throws {
        let png = try Self.makePNG(width: 600, height: 400)
        let asset = DecisionImageAsset(mediaType: .png, data: png)
        #expect(try DecisionImageNormalizer.normalize(asset, window: window) == asset)
    }

    @Test("Undecodable or unfittable images throw")
    func failures() throws {
        #expect(throws: DecisionProviderError.self) {
            try DecisionImageNormalizer.normalize(DecisionImageAsset(mediaType: .png, data: Data([0, 1, 2])), window: window)
        }
        let strip = try Self.makePNG(width: 4000, height: 4)
        #expect(throws: DecisionProviderError.self) {
            try DecisionImageNormalizer.normalize(DecisionImageAsset(mediaType: .png, data: strip), window: window)
        }
    }

    static func makePNG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    #endif
}
