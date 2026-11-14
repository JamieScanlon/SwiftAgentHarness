import Foundation

/// The wrapper a model's script runs in, and how its reply becomes an outcome.
enum ManagedBrowserScript {
    static let worldName = "computer-use-script"
    static let resultLimit = 2_000

    struct Reply: Decodable {
        var ok: Bool
        /// The returned value, already serialized, so its key order survives.
        var json: String?
        var error: String?
        var timedOut: Bool?
    }

    /// The script as the body of an async function, raced against its timeout. The reply is a JSON string, so a
    /// value that can't be serialized is reported rather than lost.
    static func expression(_ source: String, timeoutMilliseconds timeout: Int) -> String {
        """
        (async () => {
          const run = async () => {
        \(source)
          };
          let timer;
          const limit = new Promise((resolve) => { timer = setTimeout(() => resolve({ timedOut: true }), \(timeout)); });
          try {
            const outcome = await Promise.race([run().then((value) => ({ value }), (error) => ({ error })), limit]);
            if (outcome.timedOut) return JSON.stringify({ ok: false, timedOut: true });
            if ("error" in outcome) {
              const error = outcome.error;
              return JSON.stringify({ ok: false, error: error instanceof Error ? `${error.name}: ${error.message}` : String(error) });
            }
            let json;
            try { json = JSON.stringify(outcome.value === undefined ? null : outcome.value); } catch (error) { json = JSON.stringify(String(outcome.value)); }
            return JSON.stringify({ ok: true, json: json === undefined ? "null" : json });
          } finally {
            clearTimeout(timer);
          }
        })()
        """
    }

    static func outcome(_ reply: Reply?, timeoutMilliseconds timeout: Int) -> ActionOutcome {
        guard let reply else {
            return ActionOutcome(action: 0, effect: .partial, evidence: "the script's result couldn't be read", escalation: .observe)
        }
        if reply.timedOut == true {
            return ActionOutcome(action: 0, effect: .partial, evidence: "timed out after \(timeout) ms; it may still be running", escalation: .observe)
        }
        guard reply.ok else {
            return ActionOutcome(action: 0, effect: .partial, evidence: "threw: \(clip(reply.error ?? "an error", to: 500))", escalation: .observe)
        }
        return ActionOutcome(action: 0, effect: .unverifiable, evidence: "returned: \(clip(reply.json ?? "null", to: resultLimit))")
    }

    static func clip(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
