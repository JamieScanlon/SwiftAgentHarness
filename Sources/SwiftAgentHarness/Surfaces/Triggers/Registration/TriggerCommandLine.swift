import EasyJSON
import Foundation

/// A parsed control-plane command line.
///
/// Slash commands arrive as one raw string: the dispatcher splits on the first whitespace and hands
/// the tool everything after it. There is no flag parser anywhere in the harness, so without this
/// every trigger tool would hand-roll its own string matching — which is how `/active-memory` ended
/// up doing it, and doing it four more times is not a plan.
struct TriggerCommandLine: Sendable, Equatable {
    /// The first bare word, when it is not a flag: `subscribe` in `/webhook subscribe gh --rate 10`.
    var subcommand: String?
    /// Remaining bare words in order.
    var positional: [String]
    /// `--key value`, `--key=value`, and `--key` (which yields `"true"`).
    var options: [String: String]

    func option(_ names: String...) -> String? {
        for name in names {
            if let value = options[name] { return value }
        }
        return nil
    }

    func flag(_ names: String...) -> Bool? {
        for name in names {
            guard let raw = options[name] else { continue }
            switch raw.lowercased() {
            case "true", "yes", "on", "1": return true
            case "false", "no", "off", "0": return false
            default: return nil
            }
        }
        return nil
    }

    /// Positional argument at `index`, counting *after* the subcommand.
    func argument(_ index: Int) -> String? {
        index < positional.count ? positional[index] : nil
    }
}

enum TriggerCommandLineParser {
    /// Tokenizes with single/double-quote support, then splits options from positionals.
    ///
    /// Quoting matters more here than it looks: a prompt is the whole point of `/schedule create`,
    /// and prompts contain spaces.
    static func parse(_ line: String) -> TriggerCommandLine {
        let tokens = tokenize(line)
        var positional: [String] = []
        var options: [String: String] = [:]
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("--"), token.count > 2 {
                let body = String(token.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    options[String(body[body.startIndex ..< equals])] = String(body[body.index(after: equals)...])
                } else if index + 1 < tokens.count, !tokens[index + 1].hasPrefix("--") {
                    options[body] = tokens[index + 1]
                    index += 1
                } else {
                    // A bare `--flag` is `true`; that is the only reading that makes `--durable`
                    // mean what a user typing it expects.
                    options[body] = "true"
                }
            } else {
                positional.append(token)
            }
            index += 1
        }
        var subcommand: String?
        if !positional.isEmpty {
            subcommand = positional.removeFirst().lowercased()
        }
        return TriggerCommandLine(subcommand: subcommand, positional: positional, options: options)
    }

    static func tokenize(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Bridges a slash-dispatched command line into the structured arguments a trigger tool already
/// understands, so one handler serves both the model and the human.
///
/// `SlashToolDispatchArgMode.parsed` delivers `{commandName, args}` where `args` is the raw
/// remainder of the line. Rather than teaching every handler two shapes, this rewrites the command
/// line into the same JSON object the model would have produced.
enum TriggerToolArgumentBridge {
    /// True when these arguments came from a slash dispatch rather than a model tool call.
    static func isSlashDispatch(_ arguments: JSON) -> Bool {
        guard case .object(let dict) = arguments else { return false }
        return dict["commandName"] != nil && dict["args"] != nil
    }

    private static func commandLine(from arguments: JSON) -> TriggerCommandLine? {
        guard case .object(let dict) = arguments,
              case .string(let args)? = dict["args"] else { return nil }
        return TriggerCommandLineParser.parse(args)
    }

    /// Map a `/schedule …` line onto the tool call the model would have made.
    ///
    /// Returns the tool *name* alongside the arguments because the subcommand chooses which of the
    /// seven schedule tools runs — `/schedule pause abc` is `schedule_pause`, not `schedule_create`.
    static func scheduleCall(from arguments: JSON) -> (toolName: String, arguments: JSON)? {
        guard let line = commandLine(from: arguments) else { return nil }
        typealias Tools = ToolControlPlaneClassification.TriggerTools
        var fields: [String: JSON] = [:]

        func put(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            fields[key] = .string(value)
        }
        func putBool(_ key: String, _ value: Bool?) {
            guard let value else { return }
            fields[key] = .boolean(value)
        }
        func putNumber(_ key: String, _ raw: String?) {
            guard let raw, let value = Double(raw) else { return }
            fields[key] = .double(value)
        }

        switch line.subcommand ?? "list" {
        case "list":
            return (Tools.scheduleList, .object([:]))
        case "delete", "rm", "remove":
            put("id", line.argument(0))
            return (Tools.scheduleDelete, .object(fields))
        case "run", "fire":
            put("id", line.argument(0))
            return (Tools.scheduleFireNow, .object(fields))
        case "pause":
            put("id", line.argument(0))
            return (Tools.schedulePause, .object(fields))
        case "resume":
            put("id", line.argument(0))
            return (Tools.scheduleResume, .object(fields))
        case "update", "edit":
            put("id", line.argument(0))
            put("payloadText", line.option("prompt", "text") ?? line.positional.dropFirst().joined(separator: " "))
            put("title", line.option("title"))
            put("cronExpr", line.option("cron"))
            put("at", line.option("at"))
            putNumber("intervalMs", line.option("every-ms", "intervalMs"))
            put("delivery", line.option("delivery"))
            put("routingMode", line.option("routing"))
            put("timezone", line.option("tz", "timezone"))
            putBool("recurring", line.flag("recurring"))
            putBool("enabled", line.flag("enabled"))
            return (Tools.scheduleUpdate, .object(fields))
        case "create", "add":
            // `--cron`/`--at`/`--every-ms` pick the schedule kind; the rest of the line is the prompt.
            if let cron = line.option("cron") {
                fields["scheduleKind"] = .string("cron")
                fields["cronExpr"] = .string(cron)
                fields["recurring"] = .boolean(line.flag("recurring") ?? true)
            } else if let at = line.option("at") {
                fields["scheduleKind"] = .string("at")
                fields["at"] = .string(at)
                fields["recurring"] = .boolean(false)
            } else if line.option("in", "in-seconds", "inSeconds", "delay-ms", "delayMs") != nil {
                fields["scheduleKind"] = .string("at")
                fields["recurring"] = .boolean(false)
                putNumber("delayMs", line.option("delay-ms", "delayMs"))
                putNumber("inSeconds", line.option("in", "in-seconds", "inSeconds"))
            } else if let every = line.option("every-ms", "intervalMs"), let ms = Double(every) {
                fields["scheduleKind"] = .string("every")
                fields["intervalMs"] = .double(ms)
                fields["recurring"] = .boolean(line.flag("recurring") ?? true)
            } else {
                return nil
            }
            fields["payloadKind"] = .string(line.option("payloadKind") ?? "agentTurn")
            let prompt = line.option("prompt", "text") ?? line.positional.joined(separator: " ")
            fields["payloadText"] = .string(prompt)
            put("title", line.option("title"))
            put("delivery", line.option("delivery"))
            put("routingMode", line.option("routing"))
            put("timezone", line.option("tz", "timezone"))
            putBool("durable", line.flag("durable"))
            return (Tools.scheduleCreate, .object(fields))
        default:
            return nil
        }
    }

    /// Map a `/channel …` line onto the read-only `channel` tool.
    ///
    /// The mutation verbs are mapped through rather than rejected here. `/channel disable slack`
    /// reaching a "that is an owner operation, run it from the operator CLI" result is a better
    /// answer than "unknown action", and the refusal itself belongs in the provider, where the
    /// reason is known and can name the command that does work.
    static func channelArguments(from arguments: JSON) -> JSON? {
        guard let line = commandLine(from: arguments) else { return nil }
        var fields: [String: JSON] = [:]
        let action: String
        switch line.subcommand ?? "list" {
        case "list", "ls", "status": action = "list"
        case "get", "show", "info": action = "get"
        case "enable", "resume": action = "enable"
        case "disable", "pause": action = "disable"
        // `reload`/`restart` are deliberately absent. `ChannelListenerRegistry.reload(channel:)`
        // exists but has no owner client, so mapping the verb through would produce a refusal that
        // points at a command nobody can run. Unknown action is the honest answer until 4a-iii.
        default: return nil
        }
        fields["action"] = .string(action)
        if let name = line.option("channel") ?? line.argument(0) {
            fields["channel"] = .string(name)
            // `/channel status slack` names one channel, so it is a `get`; a bare `/channel status`
            // lists. Only the listing verb is promoted — `/channel disable slack` stays `disable`.
            if action == "list" { fields["action"] = .string("get") }
        }
        return .object(fields)
    }

    /// Map a `/webhook …` line onto the single action-enum `webhook` tool.
    static func webhookArguments(from arguments: JSON) -> JSON? {
        guard let line = commandLine(from: arguments) else { return nil }
        var fields: [String: JSON] = [:]

        let action: String
        switch line.subcommand ?? "list" {
        case "subscribe", "add", "create": action = "subscribe"
        case "list": action = "list"
        case "get", "show": action = "get"
        case "update", "edit": action = "update"
        case "pause", "disable": action = "pause"
        case "resume", "enable": action = "resume"
        case "delete", "rm", "remove": action = "delete"
        case "test": action = "test"
        default: return nil
        }
        fields["action"] = .string(action)
        if let name = line.argument(0) { fields["name"] = .string(name) }
        for (option, key) in [
            ("prompt", "promptTemplate"),
            ("template", "promptTemplate"),
            ("scheme", "signatureScheme"),
            ("delivery", "delivery"),
            ("url", "deliveryWebhookURL"),
            ("payload", "payload"),
        ] {
            if let value = line.option(option), !value.isEmpty {
                fields[key] = .string(value)
            }
        }
        if let rate = line.option("rate", "rateLimitPerMin"), let value = Double(rate) {
            fields["rateLimitPerMin"] = .double(value)
        }
        if let deliverOnly = line.flag("deliver-only") {
            fields["deliverOnly"] = .boolean(deliverOnly)
        }
        return .object(fields)
    }
}
