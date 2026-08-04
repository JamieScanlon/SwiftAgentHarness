import Foundation

/// Charset for names that become both a path component and part of a stable identifier.
///
/// Webhook route names and file-event subscription basenames are the same rule for the same reason —
/// the string ends up in a URL path or a filename *and* in an id (`file-periodic:<basename>`) — so
/// one definition is what keeps them from drifting.
///
/// The anchors are `\A`/`\z`, not `^`/`$`. ICU's `$` matches before a final line terminator even
/// without `.anchorsMatchLines`, so `"digest\n"` satisfied the pattern the webhook surface used —
/// and here that would produce the file `digest\n.json` and the task id `file-periodic:digest\n`.
/// The hole is real only on this surface: `WebhookRouteNaming.normalize` trims
/// `.whitespacesAndNewlines` before validating, which already covers every terminator ICU's `$`
/// special-cases. The anchors are load-bearing for basenames and defensive for routes.
enum TriggerSlug {
    static let pattern = #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#

    static func isValid(_ candidate: String) -> Bool {
        candidate.range(of: pattern, options: .regularExpression) != nil
    }
}
