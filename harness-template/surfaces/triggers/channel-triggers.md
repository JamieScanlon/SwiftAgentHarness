# Channel-Arrival Triggers

## TL;DR

Treat each chat platform's listener as a **layered intake pipeline**, not a monolithic adapter. A platform-specific transport (websocket / HTTP polling / inbound webhook) feeds an ordered chain of stages — *parse → single-instance lock → dedup → attachment download → sender authorization → mention gate → inbound debounce → trust classification* — that ends by emitting the normalized [`Trigger`](./triggers.md#the-normalized-trigger-object) object the rest of the architecture operates on. Each stage is independently testable and reusable across platforms; only the transport and parse layers are channel-specific.

The listener's contract to downstream is narrow: *a `connect()` lifecycle, a `Trigger` event stream, and an outbound `send()` paired surface* used by the output router. Everything else — message-type taxonomy, allowlist evaluation, mention semantics, debounce, reaction acknowledgment, thread-id extraction — happens inside the listener and is hidden from the activation pipeline.

This page consolidates the channel-listener architecture — componentized inbound logic, `BasePlatformAdapter(ABC)`, `BaseChannel`, and focused single-channel implementations all converge on a similar shape.

---

## Where the listener sits in the pipeline

```
              ┌────────────────────────────┐
   Slack ───▶ │                            │
   Telegram ▶ │      Channel Listener      │ ───▶ Trigger ───▶ Activation policy
   Discord ─▶ │                            │
   Email ───▶ └────────────────────────────┘
```

The listener is the leftmost stage of the trigger pipeline defined in [triggers.md](./triggers.md). It owns the protocol-specific work and emits a `Trigger` whose `source: "channel"` and whose `sourceMetadata` carries the platform identity. Once it emits, all downstream stages — idempotency, rate-limit, authorization (in the activation-policy sense), session routing, prompt building — operate on the normalized object and don't care which platform produced it.

The listener handles a smaller, tighter authorization question (is *this sender* on *this channel* allowed to talk to me at all?) before the activation policy handles the broader one (is the rate budget exhausted? has this id been seen?). The two are complementary: failing fast at the listener avoids paying activation-policy cost on dropped messages.

---

## Recommendation

### The interface contract

Every channel listener implements the same minimal interface. Platform-specific adapters extend the abstract base by overriding the protocol-specific methods.

```ts
interface ChannelListener {
  // Identity
  readonly id: ChannelId;            // "slack" | "telegram" | "discord" | ...
  readonly platformIdentity: string; // bot user id / app id / phone number — the "self"

  // Lifecycle
  connect(): Promise<ConnectResult>;
  disconnect(): Promise<void>;
  readonly state: "disconnected" | "connecting" | "connected" | "fatal";
  readonly fatalError?: { code: string; message: string; retryable: boolean };

  // Trigger emission — the contract to the activation pipeline
  onTrigger(handler: (trigger: Trigger) => Promise<void>): Unsubscribe;

  // Outbound (paired surface used by the output router; not part of intake)
  send(message: OutboundMessage): Promise<SendResult>;
  sendTyping?(chatId: string): Promise<void>;
  react?(messageId: string, emoji: string): Promise<void>;

  // Configuration (read-only at runtime; reloaded via reconnect)
  readonly config: ChannelConfig;
}
```

The `ConnectResult` distinguishes successful connect, retryable transient failure (network blip, rate-limit), and fatal misconfiguration (invalid token, missing scope, single-instance lock contention). Platform adapters surface the distinction via `fatalError` so the gateway's supervisor knows whether to retry. A fatal error stops the supervisor's exponential-backoff retry loop and writes a runtime status file the user-facing CLI can read.

The `onTrigger(handler)` callback is the *only* way the listener communicates upstream. There is no synchronous "wait for response" path; the activation pipeline is fully async. This is the right shape because platform sockets need to keep draining events while the agent runs — the only alternative is per-message backpressure, which interacts badly with multi-thread fan-in.

### The intake pipeline

Inside the listener, the journey from "raw platform event" to "emitted Trigger" is a fixed pipeline of stages. Order matters; the rationale for each placement is given.

#### 1. Transport

Whatever the platform requires: a websocket connection (Slack Socket Mode, Discord, Telegram MTProto), long-polling (Telegram getUpdates, Mattermost), HTTP webhook callbacks the listener registers a route for (Slack Events API, WhatsApp Cloud, GitHub-style email forwarders), or a third-party bridge (BlueBubbles for iMessage, Matrix-Slack bridge). The transport is the only part that's truly channel-specific; everything below it is shared.

The transport layer also owns *connection liveness* — pings, reconnects with exponential backoff (typically capped at 60s), and connection-drop detection. The recommendation: extract liveness logic to a shared `TransportSupervisor` so adapters express only the platform-specific connect logic and the supervisor handles backoff / failure reporting / status reporting uniformly.

#### 2. Single-instance lock

Acquire a scoped lock keyed by `(channel, platformIdentity)` *before* draining events. If another gateway process is already connected as the same Slack bot, the second one must fail fatal — having two listeners share a Slack subscription causes message loss (only one socket gets each event). An `_acquire_platform_lock` writes a PID file with the platform identity; on contention it sets a fatal error with the existing owner's PID surfaced to the user. Adopt this pattern; without it, a `--replace` / restart sequence races against the previous gateway.

The lock is per-identity, not per-channel — a single gateway *can* run two Slack adapters if they're different bot users.

#### 3. Parse: raw event → `MessageEvent`

Each adapter implements `parseRawEvent(raw): MessageEvent | null`. The output is the normalized message representation. A `null` return drops the event silently — this is where you reject typing indicators, presence updates, message edits if you're not subscribed to them, channel-join events, etc.

The `MessageEvent` shape:

```ts
type MessageEvent = {
  // Origin
  channel: ChannelId;
  platformMessageId: string;       // dedup key
  platformUpdateId?: string;       // platform-specific update sequence (Telegram, Discord)
  senderId: string;
  chatId: string;                  // DM peer id, channel id, group id
  threadId?: string;               // thread/topic id if scoped
  receivedAt: number;              // epoch ms

  // Content
  type: MessageType;               // "text" | "photo" | "video" | "audio" | "voice" | "document" | "sticker" | "location" | "command" | "reaction"
  text: string;                    // plain-text representation; "" for media-only messages
  attachments: Attachment[];       // see "attachment download" stage below

  // Conversation context
  replyToMessageId?: string;
  replyToText?: string;            // text of the replied-to message, if accessible
  isReplyToBot?: boolean;          // resolved by the parser using platformIdentity
  hasMention?: boolean;            // any @mention; mention-gate decides if it counts
  mentionsBot?: boolean;           // explicit @-the-bot

  // Authorization context
  isDirect: boolean;               // DM/private chat
  isGroup: boolean;                // group/channel/multi-user
  chatTypeRaw: string;             // raw platform value for diagnostics

  // Optional ephemeral context — channel-bound configuration
  channelPrompt?: string;          // per-channel system prompt (Discord channel_prompts)
  autoSkill?: string | string[];   // per-topic auto-loaded skill (Telegram DM Topics, Discord channel_skill_bindings)

  // Internal — synthetic events that bypass authorization (background completion notifications)
  internal?: boolean;

  // Raw escape hatch — adapter-specific data preserved for diagnostics and rare downstream needs
  raw: unknown;
};
```

Two things on this shape:

- **`chatTypeRaw` and `raw` are escape hatches.** Most downstream code uses the normalized fields. The escape hatches let an adapter-specific feature (Slack's assistant-thread metadata, Telegram's forum topics, WhatsApp's group-activation state) carry through without leaking upward. Use sparingly; every read of `raw` is a coupling between downstream code and a specific channel.
- **The mention/reply fields are *parser output*, not policy decisions.** The parser computes "did this message contain `@<botname>`?" and "is the replied-to message ours?" The mention gate (stage 7) decides whether those facts trigger. Keeping the two separate makes the gate testable in isolation.

#### 4. Dedup

Cache `(channel, platformMessageId)` for ~60s and silently drop repeats. Platform reconnects redeliver events — Slack Socket Mode and Telegram polling both have well-documented redelivery semantics, and Track this via a `MessageDeduplicator`. Without dedup, a reconnect during heavy chat causes the bot to respond twice to every message in the redelivery window.

Use a TTL cache, not an unbounded set; bot uptime measured in days will accumulate forever otherwise. 60s covers typical reconnect windows comfortably.

This stage is before authorization because dedup is cheaper than auth lookups (especially for adapters that fetch user-name data over the wire to evaluate the allowlist).

#### 5. Attachment download

For media messages, download attachments to a per-channel local cache directory before continuing. Two reasons: (a) the agent's tool surface (read_file, vision tools, transcription tools) wants file paths, not URLs that require platform credentials to fetch; (b) the activation pipeline's session routing happens *after* this stage, but attachments must already be local so a "user replied to this image" scenario can show the image to the next session.

The right shape: per-channel subdirectory under either an explicit env-configured root (`CHANNEL_MEDIA_DIR`), the workspace's attachments folder, or the data-dir fallback. The cache path becomes the `Attachment.localPath` in the `MessageEvent`.

Voice and audio attachments may need transcription — but transcription is downstream (transcription fires after the listener emits). The listener downloads; it doesn't transcribe.

#### 6. Sender authorization

Three-axis decision: chat type (DM vs group), sender allowlist scope (DM-allowlist vs group-allowlist), and wildcard policy.

Adopt a two-list shape:

- `dmAllowFrom`: senders allowed in DMs / private chats. Empty list with no wildcard = deny all DMs.
- `groupAllowFrom`: senders allowed in group / channel chats. Falls back to `allowFrom` if not explicitly set, unless `fallbackToAllowFrom: false`.
- `*` is the wildcard. An explicit `*` means "everyone"; an empty list means "nobody."

The wildcard-vs-empty distinction matters: a config that *forgot* to set the allowlist should fail closed (deny all), and The base adapter should do exactly this with a logged warning. Make this the default.

The `internal` flag on `MessageEvent` bypasses authorization — it's for synthetic events the harness itself generates (background-task completion notifications, reminder fires, etc.). Use this for cron-fired events that route through the channel adapter to deliver. Tag carefully; the bypass is dangerous if an external source can ever set the flag.

#### 7. Mention gate

In group chats, default to "require @mention." The gate's job is to decide whether *this* message counts as addressing the bot.

Adopt the `InboundMentionDecision` shape. Inputs split into facts and policy:

- **Facts** (computed by the parser): `wasMentioned`, `hasAnyMention`, `implicitMentionKinds: ("reply_to_bot" | "quoted_bot" | "bot_thread_participant" | "native")[]`, `canDetectMention`.
- **Policy** (from config): `isGroup`, `requireMention`, `allowedImplicitMentionKinds`, `allowTextCommands`, `hasControlCommand`, `commandAuthorized`.

Output: `effectiveWasMentioned` (booleans the rest of the pipeline reads), `shouldSkip` (hard drop), `shouldBypassMention` (for the activation pipeline's audit log).

Three implicit-mention kinds are worth supporting:

- **`reply_to_bot`** — Telegram, Discord, Slack: the user replied directly to a bot message. Treat as mention.
- **`quoted_bot`** — WhatsApp, Signal: the user quoted a bot message. Treat as mention.
- **`bot_thread_participant`** — Slack threads, Discord threads: once the bot has been mentioned in a thread, *all* subsequent messages in that thread count as mentions until the thread is reset. Track this via a `_mentioned_threads` set. This is the right behavior; without it the user has to @-mention the bot every reply, which is conversationally jarring.

`canDetectMention` is a fact the parser computes for platforms (older email formats, some SMS gateways) where mention detection isn't reliable. If `requireMention && !canDetectMention`, the gate has to either fail closed (drop) or fail open (treat as mentioned). Default closed; surface an explicit config knob (`treatUnknownMentionAs: "mention" | "no-mention"`) for the rare integrator who needs the other behavior.

#### 8. Inbound debounce

Hold the message briefly before emitting, in case it's part of a stream. Three users typing simultaneously, or a single user splitting a thought across three messages, should produce one Trigger if the messages arrive within a short window.

The right rules:

- **Text-only.** Media messages are emitted immediately (debouncing a photo would be confusing — the user expects the bot to acknowledge it now).
- **Skip debounce for control commands.** A slash command like `/stop` should fire immediately; debouncing would break the UX.
- **Configurable debounce window.** Defaults vary by channel — 1.5s for Slack/Discord (typing-indicator-driven UX expectations), 3s for Telegram, 0 for email/SMS. `resolveInboundDebounceMs` reads channel-specific overrides.

When messages arrive within the window, the adapter accumulates them and emits a single Trigger whose `text` is the concatenation. The Trigger's `platformMessageId` should be the *last* message in the burst (so a follow-up reply or edit references the conversational anchor), but `sourceMetadata` includes the full id list for audit.

This stage is after mention gating because debounced messages should all be mention-gated independently — a debounce burst where only the second message contains the mention should still fire (if the policy allows the second to mention the bot retroactively for the burst) or skip (if it doesn't). Make this an explicit policy choice; default to "any mention in the burst counts."

#### 9. Trust classification

The listener owns the trust classification. The decision is mechanical given the prior stages' outputs:

| Inputs                                                   | Trust level     | Rationale                                                                   |
|----------------------------------------------------------|-----------------|-----------------------------------------------------------------------------|
| `isDirect && senderId == primaryUser`                    | `user-direct`   | The harness's owner typing.                                                 |
| `isDirect && senderId in dmAllowFrom`                    | `known-party`   | An authorized non-primary sender. Wrap.                                     |
| `isGroup && effectiveWasMentioned && in groupAllowFrom`  | `known-party`   | An authorized group sender addressed the bot.                               |
| `isGroup && effectiveWasMentioned && wildcard groupAllowFrom (`*`)` | `unknown-party` | Anyone can mention the bot in this channel; treat content as untrusted.   |
| `internal: true`                                         | `system`        | Harness-generated. Bypasses trust wrapping downstream.                      |

`unknown-party` for wildcarded group allowlists is a deliberate choice. An open Slack channel where any workspace member can address the bot is a credible vector for prompt-injection from an attacker who joined the workspace; the envelope wrap from [input-provenance.md](./input-provenance.md) is the right defense. The gateway's audit log should flag when `unknown-party` triggers exceed a configurable rate so the user notices.

There's a fourth state worth modeling: **`user-reachable`** — a non-primary authorized DM sender who *might* respond to follow-ups but slowly. Practically, treat this as `user-direct` for prompt-builder purposes (no envelope) but include in the provenance system reminder a note like "reachable on `<channel>:<chat_id>` for follow-ups but may not respond promptly." The architecture page calls this out as an open sub-topic; the channel listener is where the distinction is observable.

#### 10. Trigger construction

The final stage assembles the `Trigger` (shape from [triggers.md](./triggers.md#the-normalized-trigger-object)):

```ts
{
  id: `${channel}:${platformMessageId}`,           // dedup key for activation policy
  source: "channel",
  sourceMetadata: {
    channel,
    chatId,
    threadId,
    senderId,
    platformMessageId,
    platformUpdateId,
    isDirect,
    isGroup,
    wasMentioned: effectiveWasMentioned,
    debounceBurst: { messageIds: [...], firstAt, lastAt },  // when applicable
  },
  receivedAt,
  payload: {
    text,
    attachments,                                   // local file paths
    replyTo: { messageId, text } | undefined,
  },
  payloadFormat: "structured",
  initiator: {
    kind: senderId === primaryUser ? "user" : "external",
    id: senderId,
  },
  trust: classifiedTrustLevel,
}
```

The session-key prefix (`channel:slack:`, `channel:telegram:`, etc.) is set by the session router (downstream), not the listener. The listener's job ends when it calls `onTrigger(trigger)`.

### Configuration shape

Each channel's config carries the listener's policy. Recommended layout:

```yaml
channels:
  slack:
    enabled: true
    credentials:
      bot_token: env:SLACK_BOT_TOKEN
      app_token: env:SLACK_APP_TOKEN
    auth:
      dm_allow_from: ["U0123456", "U0234567"]   # DMs only from these users
      group_allow_from: ["U0123456"]            # in groups, only this user can address the bot
      fallback_group_to_dm: false               # don't fall back to dm_allow_from for groups
    mention:
      require_in_groups: true
      implicit_kinds: ["reply_to_bot", "bot_thread_participant"]
      treat_unknown_as: "no-mention"            # fail closed for canDetectMention=false
    debounce:
      text_ms: 1500
    media:
      cache_dir: env:CHANNEL_MEDIA_DIR  # or use default
    ack:
      reaction_scope: "group-mentions"          # ack with emoji on inbound
    primary_user: "U0123456"
```

The `primary_user` field is what the listener uses to decide `user-direct` trust. Some platforms (email, SMS) don't have a single canonical sender id, in which case the field is a list and any match qualifies.

### Lifecycle and observability

Every listener should expose:

- **State transitions:** `disconnected → connecting → connected → fatal` (with retryable / non-retryable distinction). A runtime status file pattern — one file per platform, atomically written, readable from CLI — is the right shape.
- **Stage counters:** how many events parsed, how many dropped at each stage (dedup hit, auth deny, mention gate skip, debounced into existing burst, emitted as Trigger). Without per-stage counters, "messages aren't getting through" debugging is guesswork. Counters should be queryable via the gateway's CLI or admin API.
- **Reconnect log:** every connect, disconnect, retry, fatal — with reason codes. Useful for diagnosing platform-side outages.
- **Inflight burst window:** the count of messages currently held in debounce, surfaceable for diagnosing "I sent a message and nothing happened" — probably it's still in the debouncer.

### Outbound paired surface

The listener's `send()` is used by the [output router](./triggers.md#output-router-where-do-responses-go) downstream — it isn't part of intake, but it lives on the same listener instance because session-affinity (which thread, which chat) and credentials live there. Important sub-behaviors:

- **Length-aware truncation.** Platforms have wildly different limits (Telegram 4096 UTF-16 code units, Slack 40000 chars, Twitter 280 chars). `utf16_len` and `_prefix_within_utf16_limit` helpers are the right pattern — measure in the platform's actual unit, never naïvely slice multi-byte characters.
- **Typing indicators.** Most platforms support them; the listener exposes `sendTyping(chatId)` so the output router can keep the user informed during long agent runs. Pause typing during approval-button waits (a `_typing_paused` set is the right mechanism) — typing during a user-decision-required wait is misleading.
- **Acknowledgment reactions.** When the listener receives a `known-party` group mention, it can react with an emoji to signal "I see you" before the agent finishes. The `shouldAckReaction` policy: scope can be `all` / `direct` / `group-all` / `group-mentions` / `off`. Default `group-mentions` is the least-noisy choice.
- **Reply-thread targeting.** When the inbound `MessageEvent` has a `threadId`, the outbound `OutboundMessage` should default to that thread, not the parent channel. Cross-thread replies are almost always a bug.

---

## Alternatives

### Single concrete adapter class per platform (vs layered pipeline)

the `BasePlatformAdapter` is a single ~1100-line abstract class that mixes connection management, authorization, dedup, message-event normalization, typing indicators, fatal-error handling, proxy resolution, UTF-16 truncation, and per-session interrupt support. The advantage is that everything one platform needs is in one place. The disadvantage is that it's nearly impossible to test the auth-allowlist logic without standing up a full Slack mock — and reusing a stage across platforms means extracting it manually each time.

The layered pipeline is harder to set up the first time but pays back across the second and third platform. If you only ever ship one channel, the monolithic class is fine. If you're shipping more than three, extract.

### Webhook-only (no persistent socket) listener

For platforms that natively use HTTP webhooks (Slack Events API as opposed to Socket Mode, WhatsApp Cloud API, GitHub-as-channel), the listener has no socket to keep alive — connection management collapses to "verify the route is registered." This is simpler operationally but loses real-time delivery (Socket Mode gives sub-second response). Use webhook-only when the host environment doesn't allow outbound persistent connections (corporate firewall, restricted serverless), and accept the latency and route-registration burden.

### File-event indirection (vs direct platform integration)

An alternative: do not integrate with the platform from the listener; the agent writes a separate program that drops a JSON event file the harness watches. This pushes the "platform-specific transport" problem out of the harness entirely. Coherent for a single-user harness where the agent owns its own integrations; doesn't work when you want strong authorization or shared session state because the indirection program doesn't have access to the harness's policy and credentials.

Useful internally even if you don't use it as the primary listener model: an HTTP-webhook listener that drops a file under `workspace/events/` after validation makes the trigger queue inspectable (`ls workspace/events/` shows pending work) and turns each event into a replayable artifact.

### One listener instance per chat (vs one per platform identity)

Some implementations spawn a separate listener per active chat, so each chat has its own connection state. This is wrong for socket-based platforms — Slack's API is one socket per bot, full stop, and trying to multiplex per-chat fails the single-instance lock. For polling platforms (Telegram getUpdates, Mattermost long-poll), you *can* shard by chat-id, but it complicates dedup and fan-out and there's rarely a real reason to. Keep it one-per-identity.

---

## Anti-patterns

- **Authorization after parsing, but before deduping.** Auth lookups can be expensive (Slack `users.info` calls cost rate-limit tokens). Doing them on every redelivered event burns budget. Dedup first.
- **Storing the raw platform event in the `Trigger.payload`.** The `raw` field on `MessageEvent` is an in-listener escape hatch; it should not survive into the activation pipeline. The Trigger payload is normalized; downstream code that reads `raw` is creating per-platform coupling that bites every time you add a new platform.
- **Treating message edits as new messages.** Most platforms emit edit events; almost no harness wants to fire the agent twice on the same conversational beat. Drop edits at the parse stage unless you have an explicit "edit triggers re-evaluation" use case (rare, and best handled by treating the edit as a new conversational turn with explicit context).
- **Skipping the single-instance lock.** A `--replace` / `kill && restart` race results in two listeners briefly competing for the same socket; both lose events during the contention window. The lock isn't optional.
- **Inferring trust from message content.** "This message starts with `please`, so the sender is friendly" is exactly the prompt-injection vector the trust classifier is meant to defeat. Trust comes from `(channel, isDirect, senderId, allowlist match)`, full stop.
- **Logging full message content.** Channel triggers contain user PII by default. Stage counters and reason codes belong in logs; message text doesn't (or, if it does, it's behind a per-channel debug flag the user explicitly opts into).
- **Holding messages in the debouncer indefinitely.** A debounce window with no max-flush can stall a chat. Cap the window (3× the configured debounce, or 10s, whichever is smaller); on hitting the cap, flush the burst even if the user is still typing.
- **Using `chat_id` alone as the session key.** A user with two simultaneous Telegram threads in the same chat (forum topics) ends up with mixed conversation. Always include `threadId` in the key when the platform supports threads. A `session_key_override` field on `InboundMessage` is the seam for this.
- **Not surfacing fatal errors to the user-facing CLI.** A misconfigured Slack token results in a connect loop; without the fatal-error machinery, the user sees their messages disappear and has no signal. A runtime status file pattern is the right shape.

---
