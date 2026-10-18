import EasyJSON
import Foundation

/// An encoded wire request body plus headers the codec needs.
struct EncodedDecisionBody: Sendable {
    var body: Data
    var contentType: String
    var headers: [String: String]
}

/// Answers decoded from one wire response (before reconciliation against the request).
struct DecodedDecisionResponse: Sendable {
    var modelVersion: String?
    var answers: [String: DecisionAnswer]
    var usage: DecisionUsage
}

/// One HTTP dialect of the `decide` contract.
protocol DecisionWireCodec: Sendable {
    func encode(_ request: DecisionRequest, modelID: String, options: DecisionSurfaceOptions) throws -> EncodedDecisionBody
    func decode(_ data: Data, request: DecisionRequest, options: DecisionSurfaceOptions) throws -> DecodedDecisionResponse
}

enum DecisionResponseParsing {
    /// Parses a response body. EasyJSON has no `null`, and vendors emit nulls (e.g. an absent `reason`), so nulls
    /// are dropped from objects and arrays instead of failing the whole response.
    static func parse(_ data: Data) throws -> JSON {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let json = convert(object)
        else {
            throw DecisionProviderError.invalidResponse("body is not JSON")
        }
        return json
    }

    private static func convert(_ value: Any) -> JSON? {
        switch value {
        case is NSNull:
            return nil
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            if CFNumberIsFloatType(number) { return .double(number.doubleValue) }
            return .integer(number.intValue)
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.compactMap(convert))
        case let dictionary as [String: Any]:
            return .object(dictionary.compactMapValues(convert))
        default:
            return nil
        }
    }
}

// MARK: - SystemOne (reference dialect)

/// SystemOne codec: `state` + a map of typed questions → per-question distributions.
struct SystemOneDecisionCodec: DecisionWireCodec {
    func encode(_ request: DecisionRequest, modelID: String, options: DecisionSurfaceOptions) throws -> EncodedDecisionBody {
        if let item = request.questions.first(where: { !options.questionKinds.contains($0.question.kind) }) {
            throw DecisionProviderError.unsupportedQuestionKind(item.question.kind, surface: .systemOne)
        }
        var fields: [(String, WireJSON)] = []
        if options.sendModel {
            fields.append(("model", .string(modelID)))
        }
        let assetKeys = request.assets.keys.sorted()
        var state = WireJSON(request.state)
        if options.imagesEncoding == .imagesArray, !assetKeys.isEmpty {
            state = Self.replacingAssetReferences(in: request.state, keys: assetKeys)
        }
        fields.append(("state", state))
        fields.append(("questions", .object(request.questions.map { ($0.id, Self.encode($0.question)) })))

        var headers: [String: String] = [:]
        var parts: [(name: String, asset: DecisionImageAsset)] = []
        if !assetKeys.isEmpty {
            switch options.imagesEncoding {
            case .assets:
                fields.append(("assets", .object(assetKeys.map { key in
                    let asset = request.assets[key]!
                    return (key, .object([
                        ("type", .string("image")),
                        ("format", .string(asset.mediaType.formatName)),
                        ("data_base64", .string(asset.data.base64EncodedString())),
                    ]))
                })))
            case .parts:
                fields.append(("assets", .object(assetKeys.map { key in
                    let asset = request.assets[key]!
                    parts.append((key, asset))
                    return (key, .object([
                        ("type", .string("image")),
                        ("format", .string(asset.mediaType.formatName)),
                        ("part", .string(key)),
                    ]))
                })))
            case .imagesArray:
                fields.append(("images", .array(assetKeys.map { .string(request.assets[$0]!.dataURL) })))
            }
        }
        let needsImageFeature = !assetKeys.isEmpty || request.questionKinds.contains(.box)
        if needsImageFeature, let header = options.imagesOptInHeader {
            headers[header] = "true"
        }
        let json = WireJSON.object(fields).serialized()
        if !parts.isEmpty {
            return Self.multipart(json: json, parts: parts, headers: headers)
        }
        return EncodedDecisionBody(body: json, contentType: "application/json", headers: headers)
    }

    func decode(_ data: Data, request: DecisionRequest, options: DecisionSurfaceOptions) throws -> DecodedDecisionResponse {
        var root = try DecisionResponseParsing.parse(data)
        if let unwrap = options.unwrapKey {
            guard let inner = root[wire: unwrap] else {
                throw DecisionProviderError.invalidResponse("missing envelope key \(unwrap)")
            }
            root = inner
        }
        guard let answersObject = root[wire: "answers"]?.wireObject else {
            throw DecisionProviderError.invalidResponse("missing answers")
        }
        let questionsByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0.question) })
        var answers: [String: DecisionAnswer] = [:]
        for (id, raw) in answersObject {
            answers[id] = Self.decodeAnswer(raw, question: questionsByID[id])
        }
        let usage = DecisionUsage(
            inputTokens: root[wire: "usage"]?[wire: "input_tokens"]?.wireInt,
            outputTokens: root[wire: "usage"]?[wire: "output_tokens"]?.wireInt
        )
        return DecodedDecisionResponse(modelVersion: root[wire: "model"]?.wireString, answers: answers, usage: usage)
    }

    static func encode(_ question: DecisionQuestion) -> WireJSON {
        switch question {
        case .yesNo(let instructions, let criteria):
            var fields: [(String, WireJSON)] = [("type", .string("noul")), ("instructions", WireJSON(instructions))]
            var criteriaFields: [(String, WireJSON)] = []
            if let yes = criteria?.yes { criteriaFields.append(("true", WireJSON(yes))) }
            if let no = criteria?.no { criteriaFields.append(("false", WireJSON(no))) }
            if !criteriaFields.isEmpty { fields.append(("criteria", .object(criteriaFields))) }
            return .object(fields)
        case .choice(let instructions, let options):
            return .object([
                ("type", .string("choice")),
                ("instructions", WireJSON(instructions)),
                ("criteria", .object(options.map { ($0.id, $0.entry.map(WireJSON.init) ?? .null) })),
            ])
        case .score(let instructions, let levels):
            return .object([
                ("type", .string("score")),
                ("instructions", WireJSON(instructions)),
                ("criteria", .array(levels.map(WireJSON.init))),
            ])
        case .box(let instructions):
            return .object([("type", .string("box")), ("instructions", WireJSON(instructions))])
        }
    }

    static func decodeAnswer(_ raw: JSON, question: DecisionQuestion?) -> DecisionAnswer {
        let invalid = DecisionAnswer.unavailable(reason: .invalidDistribution)
        switch raw[wire: "type"]?.wireString {
        case "noul":
            guard let p = raw[wire: "noul"]?.wireNumber else { return invalid }
            return .yesNo(pYes: p)
        case "choice":
            guard let choice = raw[wire: "choice"]?.wireString, let probabilities = raw[wire: "probabilities"]?.wireObject else {
                return invalid
            }
            var distribution: [String: Double] = [:]
            for (option, value) in probabilities {
                guard let p = value.wireNumber else { return invalid }
                distribution[option] = p
            }
            return .choice(choice: choice, probabilities: distribution)
        case "score":
            guard let probabilities = raw[wire: "probabilities"]?.wireObject else { return invalid }
            var indexed: [Int: Double] = [:]
            for (key, value) in probabilities {
                guard let index = Int(key), let p = value.wireNumber else { return invalid }
                indexed[index] = p
            }
            let count = indexed.keys.max().map { $0 + 1 } ?? 0
            guard count == indexed.count else { return invalid }
            let ordered = (0..<count).map { indexed[$0]! }
            let expected = raw[wire: "score"]?.wireNumber ?? DecisionAnswerValidator.expectedLevel(ordered)
            return .score(expected: expected, probabilities: ordered)
        case "box":
            guard let box = raw[wire: "box"],
                  let top = box[wire: "top"]?.wireNumber, let left = box[wire: "left"]?.wireNumber,
                  let bottom = box[wire: "bottom"]?.wireNumber, let right = box[wire: "right"]?.wireNumber
            else { return invalid }
            return .box(DecisionBox(top: top, left: left, bottom: bottom, right: right), peak: nil)
        case "refusal":
            return .refusal(reason: raw[wire: "reason"]?.wireString)
        default:
            return invalid
        }
    }

    /// Images-array servers reference images by index: state strings equal to an asset key become that index.
    static func replacingAssetReferences(in state: JSON, keys: [String]) -> WireJSON {
        let indexByKey = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1, $0) })
        func rewrite(_ json: JSON) -> WireJSON {
            switch json {
            case .string(let value):
                if let index = indexByKey[value] { return .integer(index) }
                return .string(value)
            case .array(let values):
                return .array(values.map(rewrite))
            case .object(let object):
                return .object(object.keys.sorted().map { ($0, rewrite(object[$0]!)) })
            default:
                return WireJSON(json)
            }
        }
        return rewrite(state)
    }

    static func multipart(
        json: Data,
        parts: [(name: String, asset: DecisionImageAsset)],
        headers: [String: String]
    ) -> EncodedDecisionBody {
        let boundary = "sah-decision-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(json)
        append("\r\n")
        for part in parts {
            let ext = part.asset.mediaType == .png ? "png" : "jpg"
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\"; filename=\"\(part.name).\(ext)\"\r\n")
            append("Content-Type: \(part.asset.mediaType.rawValue)\r\n\r\n")
            body.append(part.asset.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return EncodedDecisionBody(body: body, contentType: "multipart/form-data; boundary=\(boundary)", headers: headers)
    }
}

// MARK: - OpenAI Decisions

/// OpenAI Decisions codec: same semantics, different field names and array containers.
struct OpenAIDecisionsCodec: DecisionWireCodec {
    /// Levels whose text is a string at most this long are sent as the label itself.
    static let shortLabelLimit = 40

    func encode(_ request: DecisionRequest, modelID: String, options: DecisionSurfaceOptions) throws -> EncodedDecisionBody {
        var questions: [WireJSON] = []
        for item in request.questions {
            questions.append(try Self.encode(item))
        }
        let stateText = DecisionEntryText.text(request.state)
        let input: WireJSON
        if request.assets.isEmpty {
            input = .string(stateText)
        } else {
            var content: [WireJSON] = [.object([("type", .string("input_text")), ("text", .string(stateText))])]
            for key in request.assets.keys.sorted() {
                content.append(.object([
                    ("type", .string("input_image")),
                    ("image_url", .string(request.assets[key]!.dataURL)),
                ]))
            }
            input = .array([.object([("role", .string("user")), ("content", .array(content))])])
        }
        let body = WireJSON.object([
            ("model", .string(modelID)),
            ("input", input),
            ("questions", .array(questions)),
        ]).serialized()
        return EncodedDecisionBody(body: body, contentType: "application/json", headers: [:])
    }

    func decode(_ data: Data, request: DecisionRequest, options: DecisionSurfaceOptions) throws -> DecodedDecisionResponse {
        let root = try DecisionResponseParsing.parse(data)
        guard let answerArray = root[wire: "answers"]?.wireArray else {
            throw DecisionProviderError.invalidResponse("missing answers")
        }
        let questionsByID = Dictionary(uniqueKeysWithValues: request.questions.map { ($0.id, $0.question) })
        var answers: [String: DecisionAnswer] = [:]
        for raw in answerArray {
            guard let name = raw[wire: "name"]?.wireString else { continue }
            answers[name] = Self.decodeAnswer(raw, question: questionsByID[name])
        }
        let usage = DecisionUsage(
            inputTokens: root[wire: "usage"]?[wire: "input_tokens"]?.wireInt,
            outputTokens: root[wire: "usage"]?[wire: "output_tokens"]?.wireInt,
            cachedInputTokens: root[wire: "usage"]?[wire: "input_tokens_details"]?[wire: "cached_tokens"]?.wireInt
        )
        return DecodedDecisionResponse(modelVersion: root[wire: "model"]?.wireString, answers: answers, usage: usage)
    }

    static func encode(_ item: DecisionQuestionItem) throws -> WireJSON {
        switch item.question {
        case .yesNo(let instructions, let criteria):
            return .object([
                ("type", .string("predicate")),
                ("name", .string(item.id)),
                ("instructions", .string(foldCriteria(instructions: instructions, criteria: criteria))),
            ])
        case .choice(let instructions, let options):
            let choices: [WireJSON] = options.map { option in
                var fields: [(String, WireJSON)] = [("value", .string(option.id))]
                if let entry = option.entry { fields.append(("description", .string(DecisionEntryText.text(entry)))) }
                return .object(fields)
            }
            return .object([
                ("type", .string("choice")),
                ("name", .string(item.id)),
                ("instructions", .string(DecisionEntryText.text(instructions))),
                ("choices", .array(choices)),
            ])
        case .score(let instructions, let levels):
            return .object([
                ("type", .string("score")),
                ("name", .string(item.id)),
                ("instructions", .string(DecisionEntryText.text(instructions))),
                ("levels", .array(levels.enumerated().map { encodeLevel($1, index: $0) })),
            ])
        case .box:
            throw DecisionProviderError.unsupportedQuestionKind(.box, surface: .openAIDecisions)
        }
    }

    /// `predicate` has no criteria field, so criteria fold into the instructions as a structured suffix.
    static func foldCriteria(instructions: DecisionEntry, criteria: YesNoCriteria?) -> String {
        var text = DecisionEntryText.text(instructions)
        var clauses: [String] = []
        if let yes = criteria?.yes { clauses.append("Answer yes if \(DecisionEntryText.text(yes))") }
        if let no = criteria?.no { clauses.append("answer no if \(DecisionEntryText.text(no))") }
        if !clauses.isEmpty {
            text += "\n\n" + clauses.joined(separator: "; ") + "."
        }
        return text
    }

    static func encodeLevel(_ level: DecisionEntry, index: Int) -> WireJSON {
        if case .string(let label) = level, label.count <= shortLabelLimit, !label.contains("\n") {
            return .object([("label", .string(label))])
        }
        return .object([("label", .string("L\(index)")), ("description", .string(DecisionEntryText.text(level)))])
    }

    static func decodeAnswer(_ raw: JSON, question: DecisionQuestion?) -> DecisionAnswer {
        let invalid = DecisionAnswer.unavailable(reason: .invalidDistribution)
        switch raw[wire: "type"]?.wireString {
        case "predicate":
            guard let p = raw[wire: "probability"]?.wireNumber else { return invalid }
            return .yesNo(pYes: p)
        case "choice":
            guard let choice = raw[wire: "choice"]?.wireString, let entries = raw[wire: "probabilities"]?.wireArray else {
                return invalid
            }
            var distribution: [String: Double] = [:]
            for entry in entries {
                guard let value = entry[wire: "value"]?.wireString, let p = entry[wire: "probability"]?.wireNumber else {
                    return invalid
                }
                distribution[value] = p
            }
            return .choice(choice: choice, probabilities: distribution)
        case "score":
            guard let entries = raw[wire: "probabilities"]?.wireArray else { return invalid }
            var indexed: [Int: Double] = [:]
            for entry in entries {
                guard let index = entry[wire: "value"]?.wireInt, let p = entry[wire: "probability"]?.wireNumber else {
                    return invalid
                }
                indexed[index] = p
            }
            let count = indexed.keys.max().map { $0 + 1 } ?? 0
            guard count == indexed.count else { return invalid }
            let ordered = (0..<count).map { indexed[$0]! }
            let expected = raw[wire: "score"]?.wireNumber ?? DecisionAnswerValidator.expectedLevel(ordered)
            return .score(expected: expected, probabilities: ordered)
        case "refusal":
            return .refusal(reason: raw[wire: "reason"]?.wireString ?? raw[wire: "refusal"]?.wireString)
        default:
            return invalid
        }
    }
}
