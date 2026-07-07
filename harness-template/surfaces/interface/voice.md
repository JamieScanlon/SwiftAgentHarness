# Voice — Recommended Architecture

## TL;DR

Voice is an **alternate input/output codec on the same conversation**, not a separate surface or a method bolted onto a text channel. A voice turn produces the same conversation events as a typed turn; speech-to-text is just another way to fill the inbound envelope, and text-to-speech is just another way to render output. This page goes deeper than the [interface README](./README.md) (§ Rec 9) on the provider slots that make it work.

The prescriptive shape:

1. **Voice in/out are distinct provider capability slots, like models — not channel methods.** Register **speech** (TTS / batch STT), **realtime transcription** (streaming speech-in), and **realtime voice** (duplex live conversation) as separate provider slots ([extensibility](../../cross-cutting/extensibility/)), each with its own contract — the same capability-record discipline the [providers](../../backends/providers/) page applies to text models.
2. **Provider fallback, the same as model failover.** A hosted TTS as primary with a local/system TTS as fallback is the [Model Pool](../../core/model-pool/) failover pattern applied to speech: classify the failure, fall through the chain, keep the turn alive. Each provider is declared primary-or-fallback.
3. **Voice is a codec, not a conversation.** Speech-in normalizes to the same trust-classed [inbound envelope](../triggers/) any surface produces; speech-out renders the same output the text path renders. The conversation, its events, and its history are identical whether the turn was spoken or typed. Don't model voice as a parallel conversation.
4. **Activation mode is surface-specific; the provider slot is shared.** Wake-word, push-to-talk, and continuous-listen are properties of the *surface* (a desktop app, a phone, a call). The STT/TTS *provider* underneath is the same regardless. Keep activation in the surface and the codec in the shared slot.
5. **Turn-based (STT+TTS) and duplex realtime voice are different contracts.** Transcribe-then-respond-then-speak is a sequence of batch/streaming codec steps on a normal turn. A live duplex voice session (barge-in, simultaneous listen/speak) is its own provider slot with its own lifecycle. Don't force one into the other.

The unifying idea: voice rides the portable-input-envelope and portable-output story exactly like every other surface. Build the codec as provider slots with fallback; let each surface own how listening is triggered.

---

## Where this fits

The [interface README](./README.md) asymmetry — *input is surface-native, output is portable* — applies cleanly to voice. Speech-in is a surface-native input mode (a wake-word recognizer, a phone's mic) that, once received, normalizes to the same inbound envelope as a typed message. Speech-out is the portable output rendered through an audio codec instead of a text renderer. So voice doesn't need a new architectural plane; it needs **codecs at the surface boundary** plus **provider slots** for the speech models that power them.

Two consequences this page keeps returning to:

- **Voice is capability-shaped, like models.** TTS, streaming STT, and duplex voice are *capabilities* the harness selects a provider for — with cost, latency, and quality trade-offs, and the need for fallback — exactly like text inference. So they belong in provider slots, selected and failed-over like models, not as `send_voice` methods welded onto a channel.
- **Voice is conversation-transparent.** A spoken "what's the weather" and a typed one produce the same turn, the same events on the [conversation](../../core/conversation-manager/) stream, the same history. The codec is at the edges; the conversation in the middle is unchanged.

---

## Recommendation

### Voice in/out as distinct provider slots

Register voice capabilities as separate provider slots, each with its own contract, rather than as one "voice" object or as channel methods:

- **Speech** — text-to-speech synthesis, and batch speech-to-text. The codec for rendering a finished reply as audio and transcribing a recorded clip.
- **Realtime transcription** — *streaming* speech-in: partial transcripts as the user talks, with endpointing (knowing when an utterance ends).
- **Realtime voice** — a *duplex* live session: the model listens and speaks concurrently, with barge-in.

These are three contracts, not three flavors of one, because their shapes genuinely differ — batch TTS returns an audio blob; streaming STT yields incremental partials; duplex voice is a bidirectional stream with interruption. A single vendor may fill several slots, but each slot is registered and selected independently ([extensibility](../../cross-cutting/extensibility/)), the same way the [providers](../../backends/providers/) page argues image-gen and text inference are parallel slots, not one provider object.

### Provider fallback, like model failover

Speech providers fail — a hosted TTS times out, an API key lapses, a quota is exhausted — and a voice turn shouldn't die because the primary synth is down. Apply the [Model Pool](../../core/model-pool/) failover discipline:

- Each provider is declared **primary** or **fallback**; the harness tries them in order.
- A **hosted, high-quality TTS as primary, a local/system TTS as fallback** is the canonical chain: best quality when available, always-works floor when not.
- The provider classifies its failure (transient / quota / auth) and the selector decides whether to retry or fall through — the same classification-vs-policy split the [providers](../../backends/providers/) page draws for text.

Voice fallback matters *more* than text fallback in one way: a silent failure is worse on a voice surface, where the user is waiting to *hear* something and a dropped reply is just silence.

### Voice is a codec on the same conversation

The load-bearing modeling decision: **a voice turn is a normal turn with codecs at the edges.**

- **Speech-in → the inbound envelope.** STT transcribes the utterance; the result fills the same trust-classed [inbound envelope](../triggers/) a typed message would, and routes to the same conversation. The transcript is the message; the audio is an attachment (a [blob](../../backends/persistence/)) if retained at all.
- **Output → speech-out.** The reply is the same output the text path produces; the audio codec renders it (optionally carrying a hidden spoken transcript distinct from any visible caption). The model doesn't author "voice output" — it authors output, which a voice surface speaks.

So the conversation, its events, and its history are codec-independent. A user can start a turn by voice and read the reply as text on another attached client, because both are views of one conversation. **Don't create a separate "voice conversation"** — that splits history and breaks multi-client attach.

### Activation mode is surface-specific

*How listening is triggered* is a property of the surface, not the speech provider:

- **Wake-word** — an always-on recognizer waits for a trigger phrase, then captures until a silence window, with hard-stop and debounce guards (desktop/phone).
- **Push-to-talk** — hold a key/button to capture; release to finalize (desktop).
- **Continuous / talk mode** — sustained listening for a back-and-forth (phone, hands-free).
- **Call** — a telephony session is its own activation with its own lifecycle.

All of these can sit on top of the *same* STT provider slot. The recognizer, the overlay, the silence-window tuning, the lifecycle invariants ("if enabled and permitted, the recognizer should be listening") are surface-local; the speech model they feed is shared. Keep the activation machinery in the surface plugin and the codec in the provider slot, so a new activation mode doesn't touch the provider and a new provider doesn't touch activation.

### Turn-based and duplex realtime are different contracts

Two genuinely different interaction shapes, kept as different slots:

- **Turn-based voice** — listen (streaming STT) → endpoint → run a normal turn → speak (TTS). A sequence of codec steps around an ordinary turn. The dominant, simpler case; works with batch or streaming STT plus TTS.
- **Duplex realtime voice** — a continuous bidirectional session where the model listens and speaks at once and the user can barge in mid-reply. Its own provider slot, its own session lifecycle, its own interruption semantics.

Don't simulate duplex by racing turn-based pieces, and don't force a simple wake-word-and-reply flow through a duplex session it doesn't need. Pick the slot that matches the interaction.

---

## Alternatives

### Voice as methods on a channel

Bolt `send_voice` / `transcribe` onto each messaging channel adapter.

**When this works:** when exactly one channel does voice and it'll never spread — a quick way to ship voice notes on one platform.

**Why not as the default:** it conflates *capability* (speech synthesis/recognition, with cost/quality/fallback) with *transport* (a channel's wire). Voice can't be selected or failed-over independently, two channels can't share one TTS provider without duplication, and the model's surface fragments. Voice is a provider capability that *any* surface can use, not a channel feature — the same argument the [channels](./channels.md) page makes for keeping the shared `message` tool out of per-channel send methods.

### A single TTS provider, no fallback

Wire one speech provider directly, no chain.

**When this works:** a local-only deployment with a reliable local synth, where "down" isn't a real failure mode.

**Why not as the default:** a hosted synth *will* have a bad day, and on a voice surface that means silence — the worst failure mode. A primary-plus-fallback chain (hosted → local) costs little and removes the silent-failure case.

### Voice as a separate conversation

Model a voice session as its own conversation distinct from the user's text thread.

**When this works:** essentially never for an assistant the user also texts; maybe for a standalone phone-only IVR.

**Why not:** it splits history, breaks the "read it later as text" affordance, and defeats multi-client attach. Voice is a codec on the conversation the user already has; keep one conversation, many codecs.

---

## Anti-patterns

- **Voice in/out welded onto a channel as methods.** Couples capability to transport; can't select or fail-over voice independently; fragments the model's surface. Register speech, realtime transcription, and realtime voice as provider slots.

- **One "voice" object for all three contracts.** Batch TTS, streaming STT, and duplex voice have genuinely different shapes; a single object forces leaky branching. Three slots, three contracts.

- **No fallback synth.** A failed hosted TTS becomes silence — the worst outcome on a voice surface. Always have a local/system fallback in the chain.

- **A separate voice conversation.** Splits history and breaks multi-client read-back. Voice is an alternate codec on the same conversation, with the same events and history.

- **Activation mode baked into the provider.** Wake-word vs push-to-talk vs continuous is a surface property; baking it into the STT provider means a new activation mode forces a provider change. Keep activation surface-local, the codec shared.

- **Simulating duplex by racing turn-based pieces.** Barge-in and simultaneous listen/speak need a real duplex session, not a TTS and an STT in a footrace. Use the realtime-voice slot for duplex.

- **Losing the trust class on transcribed input.** A transcribed voice message is still inbound content with a provenance/trust level; STT must fill the same trust-classed envelope, not a bypass that treats spoken input as trusted.

---

## Cross-references

- [Interface README](./README.md) — § Rec 9; the input-native/output-portable asymmetry that makes voice a codec, not a plane.
- [Providers](../../backends/providers/) — the capability-slot model (speech as parallel slots) and the classify-vs-policy failover split.
- [Model Pool](../../core/model-pool/) — the failover discipline voice-provider fallback mirrors.
- [Extensibility](../../cross-cutting/extensibility/) — `registerSpeechProvider` / `registerRealtimeTranscriptionProvider` / `registerRealtimeVoiceProvider` capability registrations.
- [Conversation Manager](../../core/conversation-manager/) — the single conversation a voice turn shares with text.
- [Triggers / input-provenance](../triggers/) — the trust-classed inbound envelope speech-in fills.
- [Persistence](../../backends/persistence/) — retained audio as a blob attachment, not inline.
- [channels.md](./channels.md) — why voice is a shared capability, not a per-channel method (parallel to the shared `message` tool).
