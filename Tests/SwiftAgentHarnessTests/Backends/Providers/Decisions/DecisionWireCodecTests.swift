import EasyJSON
import Foundation
import Testing
@testable import SwiftAgentHarness

/// Wire bodies may contain `null` (an option with no description), which EasyJSON cannot represent.
private func decode(_ body: EncodedDecisionBody) throws -> JSON {
    try DecisionResponseParsing.parse(body.body)
}

private let mixedRequest = DecisionRequest(
    state: .object(["command": .string("git push --force"), "cwd": .string("/repo")]),
    questions: [
        DecisionQuestionItem("destructive", .yesNo(
            instructions: .string("Does the command destroy data?"),
            criteria: YesNoCriteria(yes: .string("history is rewritten"), no: .string("nothing is lost"))
        )),
        DecisionQuestionItem("category", .choice(instructions: .string("Which category?"), options: [
            DecisionOption("vcs", .string("version control")),
            DecisionOption("fs"),
        ])),
        DecisionQuestionItem("risk", .score(instructions: .string("How risky?"), levels: [.string("low"), .string("medium"), .string("high")])),
    ]
)

@Suite("SystemOne codec")
struct SystemOneCodecTests {
    let codec = SystemOneDecisionCodec()
    let options = DecisionSurfaceOptions(profile: DecisionProfiles.systemOne())

    @Test("Encodes state plus an ordered question map using the reference field names")
    func encodesQuestions() throws {
        let encoded = try codec.encode(mixedRequest, modelID: "decider-2026-09", options: options)
        #expect(encoded.contentType == "application/json")
        let json = try decode(encoded)
        #expect(json[test: "model"]?.testString == "decider-2026-09")
        #expect(json[test: "state"]?[test: "command"]?.testString == "git push --force")
        let questions = try #require(json[test: "questions"])
        #expect(questions[test: "destructive"]?[test: "type"]?.testString == "noul")
        #expect(questions[test: "destructive"]?[test: "criteria"]?[test: "true"]?.testString == "history is rewritten")
        #expect(questions[test: "destructive"]?[test: "criteria"]?[test: "false"]?.testString == "nothing is lost")
        #expect(questions[test: "category"]?[test: "type"]?.testString == "choice")
        #expect(questions[test: "category"]?[test: "criteria"]?[test: "vcs"]?.testString == "version control")
        #expect(questions[test: "risk"]?[test: "criteria"]?.testArray?.count == 3)

        // Order and ids stay stable on the wire.
        let body = String(decoding: encoded.body, as: UTF8.self)
        let destructive = try #require(body.range(of: "\"destructive\""))
        let category = try #require(body.range(of: "\"category\""))
        let risk = try #require(body.range(of: "\"risk\""))
        #expect(destructive.lowerBound < category.lowerBound && category.lowerBound < risk.lowerBound)
        #expect(body.contains("\"fs\":null"))
    }

    @Test("Omits model when the server's modelField quirk is omit")
    func omitsModel() throws {
        let profile = DecisionProfiles.systemOne(extraFeatures: [
            DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")]),
        ])
        let encoded = try codec.encode(mixedRequest, modelID: "m", options: DecisionSurfaceOptions(profile: profile))
        #expect(try decode(encoded)[test: "model"] == nil)
    }

    @Test("Inline assets use data_base64 and add the images opt-in header")
    func inlineAssets() throws {
        let profile = DecisionProfiles.systemOne(images: FeatureSupport(params: [
            "encoding": .string("assets"), "optInHeader": .string("X-Decider-Images"),
        ]))
        let request = DecisionRequest(
            state: .object(["screenshot": .string("shot")]),
            assets: ["shot": DecisionImageAsset(mediaType: .png, data: Data([1, 2, 3]))],
            questions: [DecisionQuestionItem("button", .box(instructions: .string("Find the submit button")))]
        )
        let encoded = try codec.encode(request, modelID: "m", options: DecisionSurfaceOptions(profile: profile))
        #expect(encoded.headers["X-Decider-Images"] == "true")
        let asset = try #require(try decode(encoded)[test: "assets"]?[test: "shot"])
        #expect(asset[test: "type"]?.testString == "image")
        #expect(asset[test: "format"]?.testString == "png")
        #expect(asset[test: "data_base64"]?.testString == Data([1, 2, 3]).base64EncodedString())
    }

    @Test("Box questions alone still set the images opt-in header")
    func boxHeader() throws {
        let profile = DecisionProfiles.systemOne(images: FeatureSupport(params: ["optInHeader": .string("X-Img")]))
        var request = DecisionRequest(
            state: .string("s"),
            assets: ["a": DecisionImageAsset(mediaType: .jpeg, data: Data([9]))],
            questions: [DecisionQuestionItem("b", .box(instructions: .string("find")))]
        )
        #expect(try codec.encode(request, modelID: "m", options: DecisionSurfaceOptions(profile: profile)).headers["X-Img"] == "true")
        request = DecisionFixtures.yesNoRequest()
        #expect(try codec.encode(request, modelID: "m", options: DecisionSurfaceOptions(profile: profile)).headers.isEmpty)
    }

    @Test("Images-array servers get data URLs and index references in state")
    func imagesArray() throws {
        let profile = DecisionProfiles.systemOne(images: FeatureSupport(params: ["encoding": .string("images-array")]))
        let request = DecisionRequest(
            state: .object(["before": .string("img-a"), "after": .string("img-b"), "note": .string("keep")]),
            assets: [
                "img-b": DecisionImageAsset(mediaType: .jpeg, data: Data([2])),
                "img-a": DecisionImageAsset(mediaType: .png, data: Data([1])),
            ],
            questions: [DecisionQuestionItem("changed", .yesNo(instructions: .string("Did it change?")))]
        )
        let json = try decode(try codec.encode(request, modelID: "m", options: DecisionSurfaceOptions(profile: profile)))
        #expect(json[test: "images"]?.testArray?.count == 2)
        #expect(json[test: "images"]?[test: 0]?.testString?.hasPrefix("data:image/png;base64,") == true)
        #expect(json[test: "state"]?[test: "before"]?.testNumber == 0)
        #expect(json[test: "state"]?[test: "after"]?.testNumber == 1)
        #expect(json[test: "state"]?[test: "note"]?.testString == "keep")
        #expect(json[test: "assets"] == nil)
    }

    @Test("Parts encoding sends multipart/form-data with a JSON request part and one part per image")
    func multipart() throws {
        let profile = DecisionProfiles.systemOne(images: FeatureSupport(params: ["encoding": .string("parts")]))
        let request = DecisionRequest(
            state: .string("see image"),
            assets: ["shot": DecisionImageAsset(mediaType: .png, data: Data("PNGDATA".utf8))],
            questions: [DecisionQuestionItem("ok", .yesNo(instructions: .string("ok?")))]
        )
        let encoded = try codec.encode(request, modelID: "m", options: DecisionSurfaceOptions(profile: profile))
        #expect(encoded.contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: encoded.body, as: UTF8.self)
        #expect(body.contains("name=\"request\""))
        #expect(body.contains("\"part\":\"shot\""))
        #expect(body.contains("name=\"shot\"; filename=\"shot.png\""))
        #expect(body.contains("PNGDATA"))
    }

    @Test("Rejects question kinds the binding does not declare")
    func unsupportedKind() {
        let profile = DecisionProfiles.systemOne(questionKinds: [.yesNo])
        #expect(throws: DecisionProviderError.unsupportedQuestionKind(.choice, surface: .systemOne)) {
            try codec.encode(mixedRequest, modelID: "m", options: DecisionSurfaceOptions(profile: profile))
        }
    }

    @Test("Decodes every answer type, maps string-keyed levels to an array, and drops vendor confidence")
    func decodes() throws {
        let body = """
        { "model": "decider-2026-09",
          "answers": {
            "destructive": { "type": "noul", "noul": 0.95 },
            "category": { "type": "choice", "choice": "vcs", "probabilities": { "vcs": 0.88, "fs": 0.12 }, "confidence": 0.81 },
            "risk": { "type": "score", "score": 1.05, "legend": { "0": "low" },
                      "probabilities": { "0": 0.1, "1": 0.75, "2": 0.15 }, "confidence": 0.92 } },
          "usage": { "input_tokens": 318, "output_tokens": 34 } }
        """
        let decoded = try codec.decode(Data(body.utf8), request: mixedRequest, options: options)
        #expect(decoded.modelVersion == "decider-2026-09")
        #expect(decoded.answers["destructive"] == .yesNo(pYes: 0.95))
        #expect(decoded.answers["category"] == .choice(choice: "vcs", probabilities: ["vcs": 0.88, "fs": 0.12]))
        #expect(decoded.answers["risk"] == .score(expected: 1.05, probabilities: [0.1, 0.75, 0.15]))
        #expect(decoded.usage.inputTokens == 318)
        #expect(decoded.usage.outputTokens == 34)
    }

    @Test("Decodes box and refusal answers; unknown types become invalid-distribution")
    func decodesBoxAndRefusal() {
        let box = SystemOneDecisionCodec.decodeAnswer(
            .object(["type": .string("box"), "box": .object([
                "top": .double(0.1), "bottom": .double(0.4), "left": .double(0.2), "right": .double(0.6),
            ]), "confidence": .double(0.7)]),
            question: nil
        )
        #expect(box == .box(DecisionBox(top: 0.1, left: 0.2, bottom: 0.4, right: 0.6), peak: nil))
        #expect(SystemOneDecisionCodec.decodeAnswer(.object(["type": .string("refusal"), "reason": .string("policy")]), question: nil)
            == .refusal(reason: "policy"))
        #expect(SystemOneDecisionCodec.decodeAnswer(.object(["type": .string("mystery")]), question: nil)
            == .unavailable(reason: .invalidDistribution))
        #expect(SystemOneDecisionCodec.decodeAnswer(.object(["type": .string("score"), "probabilities": .object(["0": .double(0.5), "2": .double(0.5)])]), question: nil)
            == .unavailable(reason: .invalidDistribution))
    }

    @Test("Unwraps a platform envelope when configured")
    func unwrapsEnvelope() throws {
        let profile = DecisionProfiles.systemOne(extraFeatures: [
            DecisionFeatureKey.envelope: FeatureSupport(params: ["unwrap": .string("result")]),
        ])
        let body = """
        {"success": true, "errors": [], "result": {"model": "edge-decider", "answers": {"safe": {"type": "noul", "noul": 0.2}}}}
        """
        let decoded = try codec.decode(Data(body.utf8), request: DecisionFixtures.yesNoRequest(), options: DecisionSurfaceOptions(profile: profile))
        #expect(decoded.modelVersion == "edge-decider")
        #expect(decoded.answers["safe"] == .yesNo(pYes: 0.2))
        #expect(throws: DecisionProviderError.self) {
            try codec.decode(Data("{\"answers\":{}}".utf8), request: DecisionFixtures.yesNoRequest(), options: DecisionSurfaceOptions(profile: profile))
        }
    }

    @Test("Vendor nulls are dropped rather than failing the whole response")
    func toleratesNulls() throws {
        let body = """
        { "model": "decider-2026-09", "request_id": null,
          "answers": {
            "destructive": { "type": "noul", "noul": 0.4, "confidence": null },
            "category": { "type": "refusal", "reason": null },
            "risk": { "type": "score", "legend": null, "probabilities": { "0": 0.2, "1": 0.3, "2": 0.5 } } },
          "usage": { "input_tokens": 12, "output_tokens": null } }
        """
        let decoded = try codec.decode(Data(body.utf8), request: mixedRequest, options: options)
        #expect(decoded.answers["destructive"] == .yesNo(pYes: 0.4))
        #expect(decoded.answers["category"] == .refusal(reason: nil))
        guard case .score(let expected, _)? = decoded.answers["risk"] else { Issue.record("expected score"); return }
        #expect(abs(expected - 1.3) < 1e-12)
        #expect(decoded.usage.inputTokens == 12)
        #expect(decoded.usage.outputTokens == nil)
    }

    @Test("Booleans, integers, and doubles keep their JSON types")
    func numericTypes() throws {
        let json = try DecisionResponseParsing.parse(Data(#"{"b": true, "i": 3, "d": 0.5}"#.utf8))
        #expect(json[test: "b"].map { if case .boolean(true) = $0 { return true } else { return false } } == true)
        #expect(json[test: "i"].map { if case .integer(3) = $0 { return true } else { return false } } == true)
        #expect(json[test: "d"]?.testNumber == 0.5)
    }

    @Test("Non-JSON or answer-less bodies are invalid responses")
    func invalidBodies() {
        #expect(throws: DecisionProviderError.invalidResponse("body is not JSON")) {
            try codec.decode(Data("<html>".utf8), request: mixedRequest, options: options)
        }
        #expect(throws: DecisionProviderError.invalidResponse("missing answers")) {
            try codec.decode(Data("{}".utf8), request: mixedRequest, options: options)
        }
    }
}

@Suite("OpenAI Decisions codec")
struct OpenAIDecisionsCodecTests {
    let codec = OpenAIDecisionsCodec()
    let options = DecisionSurfaceOptions(profile: DecisionProfiles.openAIDecisions())

    @Test("Encodes predicate, choice, and score questions as an ordered array keyed by name")
    func encodes() throws {
        let json = try decode(try codec.encode(mixedRequest, modelID: "gpt-decide-1", options: options))
        #expect(json[test: "model"]?.testString == "gpt-decide-1")
        let questions = try #require(json[test: "questions"]?.testArray)
        #expect(questions.map { $0[test: "name"]?.testString } == ["destructive", "category", "risk"])

        let predicate = questions[0]
        #expect(predicate[test: "type"]?.testString == "predicate")
        let instructions = try #require(predicate[test: "instructions"]?.testString)
        #expect(instructions.hasPrefix("Does the command destroy data?"))
        #expect(instructions.contains("Answer yes if history is rewritten; answer no if nothing is lost."))

        let choices = try #require(questions[1][test: "choices"]?.testArray)
        #expect(choices[0][test: "value"]?.testString == "vcs")
        #expect(choices[0][test: "description"]?.testString == "version control")
        #expect(choices[1][test: "value"]?.testString == "fs")
        #expect(choices[1][test: "description"] == nil)

        let levels = try #require(questions[2][test: "levels"]?.testArray)
        #expect(levels.map { $0[test: "label"]?.testString } == ["low", "medium", "high"])
    }

    @Test("Long or structured levels get synthesized labels with the text as description")
    func synthesizedLabels() {
        let long = OpenAIDecisionsCodec.encodeLevel(.string(String(repeating: "x", count: 60)), index: 2)
        #expect(long == .object([("label", .string("L2")), ("description", .string(String(repeating: "x", count: 60)))]))
        let structured = OpenAIDecisionsCodec.encodeLevel(.object(["severity": .string("high")]), index: 0)
        guard case .object(let pairs) = structured else { Issue.record("expected object"); return }
        #expect(pairs.first?.1 == .string("L0"))
    }

    @Test("Object state is sent as stable pretty-printed JSON text; images become input_image parts")
    func stateSerialization() throws {
        let plain = try decode(try codec.encode(mixedRequest, modelID: "m", options: options))
        let text = try #require(plain[test: "input"]?.testString)
        #expect(text.contains("\"command\" : \"git push --force\""))
        #expect(text.range(of: "\"command\"")!.lowerBound < text.range(of: "\"cwd\"")!.lowerBound)

        var withImage = mixedRequest
        withImage.assets = ["shot": DecisionImageAsset(mediaType: .png, data: Data([7]))]
        let json = try decode(try codec.encode(withImage, modelID: "m", options: options))
        let content = try #require(json[test: "input"]?[test: 0]?[test: "content"]?.testArray)
        #expect(json[test: "input"]?[test: 0]?[test: "role"]?.testString == "user")
        #expect(content[0][test: "type"]?.testString == "input_text")
        #expect(content[1][test: "type"]?.testString == "input_image")
        #expect(content[1][test: "image_url"]?.testString?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test("The dialect has no box kind")
    func noBox() {
        let request = DecisionRequest(
            state: .string("s"),
            assets: ["a": DecisionImageAsset(mediaType: .png, data: Data([1]))],
            questions: [DecisionQuestionItem("b", .box(instructions: .string("find")))]
        )
        #expect(throws: DecisionProviderError.unsupportedQuestionKind(.box, surface: .openAIDecisions)) {
            try codec.encode(request, modelID: "m", options: options)
        }
        #expect(!options.questionKinds.contains(.box))
    }

    @Test("Decodes predicate, choice, score ordered by value, refusal, and cached token usage")
    func decodes() throws {
        let body = """
        { "model": "gpt-decide-1-2026-08",
          "answers": [
            { "type": "predicate", "name": "destructive", "probability": 0.93 },
            { "type": "choice", "name": "category", "choice": "vcs", "confidence": 0.7,
              "probabilities": [ { "value": "fs", "probability": 0.2 }, { "value": "vcs", "probability": 0.8 } ] },
            { "type": "score", "name": "risk", "score": 1.2,
              "probabilities": [ { "label": "high", "value": 2, "probability": 0.3 },
                                 { "label": "low", "value": 0, "probability": 0.1 },
                                 { "label": "medium", "value": 1, "probability": 0.6 } ] } ],
          "usage": { "input_tokens": 120, "output_tokens": 0, "total_tokens": 120, "input_tokens_details": { "cached_tokens": 64 } } }
        """
        let decoded = try codec.decode(Data(body.utf8), request: mixedRequest, options: options)
        #expect(decoded.modelVersion == "gpt-decide-1-2026-08")
        #expect(decoded.answers["destructive"] == .yesNo(pYes: 0.93))
        #expect(decoded.answers["category"] == .choice(choice: "vcs", probabilities: ["fs": 0.2, "vcs": 0.8]))
        #expect(decoded.answers["risk"] == .score(expected: 1.2, probabilities: [0.1, 0.6, 0.3]))
        #expect(decoded.usage.inputTokens == 120)
        #expect(decoded.usage.cachedInputTokens == 64)

        let refusal = OpenAIDecisionsCodec.decodeAnswer(.object(["type": .string("refusal"), "name": .string("x")]), question: nil)
        #expect(refusal == .refusal(reason: nil))
    }
}

@Suite("Decision surface options")
struct DecisionSurfaceOptionsTests {
    @Test("Quirks are read from binding features and limits, not code branches")
    func quirks() {
        let profile = DecisionProfiles.systemOne(
            questionKinds: [.yesNo, .choice],
            images: FeatureSupport(params: [
                "encoding": .string("images-array"), "optInHeader": .string("X-I"),
                "edgePx": .array([.integer(280), .integer(1568)]),
                "totalPixels": .array([.integer(78_400), .integer(2_458_624)]),
            ]),
            longContext: FeatureSupport(params: ["optInHeader": .string("X-Long")]),
            languages: FeatureSupport(params: ["strong": .array([.string("en")]), "weak": .array([.string("ja")])]),
            extraFeatures: [
                DecisionFeatureKey.envelope: FeatureSupport(params: ["unwrap": .string("result")]),
                DecisionFeatureKey.modelField: FeatureSupport(params: ["mode": .string("omit")]),
                DecisionFeatureKey.endpoint: FeatureSupport(params: ["path": .string("ai/run/decide")]),
                DecisionFeatureKey.compression: FeatureSupport(params: ["encoding": .string("gzip")]),
            ],
            limits: ContractLimits(contextTokens: 65_536, maxItemsPerCall: 64, maxOptions: 255, scoreLevels: 2...10)
        )
        let options = DecisionSurfaceOptions(profile: profile)
        #expect(options.questionKinds == [.yesNo, .choice])
        #expect(options.unwrapKey == "result")
        #expect(!options.sendModel)
        #expect(options.imagesEncoding == .imagesArray)
        #expect(options.imagesOptInHeader == "X-I")
        #expect(options.imageWindow == DecisionImageNormalizer.Window(edgePx: 280...1568, totalPixels: 78_400...2_458_624))
        #expect(options.longContextOptInHeader == "X-Long")
        #expect(options.maxQuestionsPerCall == 64)
        #expect(options.path == "ai/run/decide")
        #expect(options.gzip)
        #expect(options.languagesStrong == ["en"])
        #expect(options.languagesWeak == ["ja"])
    }

    @Test("Defaults per surface")
    func defaults() {
        let systemOne = DecisionSurfaceOptions(profile: DecisionProfiles.systemOne())
        #expect(systemOne.path == "v1/systemone")
        #expect(systemOne.sendModel)
        #expect(!systemOne.imagesSupported)
        let openAI = DecisionSurfaceOptions(profile: DecisionProfiles.openAIDecisions())
        #expect(openAI.path == "v1/decisions")
        #expect(openAI.imagesSupported)
        #expect(openAI.questionKinds == [.yesNo, .choice, .score])
    }

    @Test("Rejection explains kinds, images, and option counts")
    func rejection() {
        let options = DecisionSurfaceOptions(profile: DecisionProfiles.systemOne(
            questionKinds: [.yesNo, .choice],
            limits: ContractLimits(maxOptions: 2)
        ))
        #expect(options.rejection(for: DecisionFixtures.yesNoRequest()) == nil)
        #expect(options.rejection(for: mixedRequest) == "question kind score unsupported")
        let threeOptions = DecisionRequest(state: .string("s"), questions: [
            DecisionQuestionItem("c", .choice(instructions: .string("?"), options: [DecisionOption("a"), DecisionOption("b"), DecisionOption("c")])),
        ])
        #expect(options.rejection(for: threeOptions) == "3 options exceed maxOptions 2")
        var withImage = DecisionFixtures.yesNoRequest()
        withImage.assets = ["a": DecisionImageAsset(mediaType: .png, data: Data([1]))]
        #expect(options.rejection(for: withImage) == "image assets unsupported")
    }
}

@Suite("Wire JSON")
struct WireJSONTests {
    @Test("Preserves object key order and escapes strings")
    func serialization() {
        let json = WireJSON.object([
            ("z", .string("a\"b\\c\n")),
            ("a", .array([.integer(1), .number(0.5), .bool(true), .null])),
        ])
        #expect(String(decoding: json.serialized(), as: UTF8.self) == #"{"z":"a\"b\\c\n","a":[1,0.5,true,null]}"#)
    }

    @Test("Converts EasyJSON with sorted keys")
    func fromEasyJSON() {
        let json = WireJSON(.object(["b": .integer(2), "a": .double(3)]))
        #expect(String(decoding: json.serialized(), as: UTF8.self) == #"{"a":3,"b":2}"#)
    }

    @Test("Entry text passes strings through and pretty-prints structure")
    func entryText() {
        #expect(DecisionEntryText.text(.string("plain")) == "plain")
        #expect(DecisionEntryText.text(.object(["k": .string("v")])).contains("\"k\" : \"v\""))
    }
}
