# Channel (Interface leaf)

Messaging platforms are **surfaces** in the harness: they expose the same portable contracts as TUI and other Interface leaves, wired through [`StreamingSurfaceEngine`](../Streaming/StreamingSurfaceEngine.swift) and the shared `message` tool.

## Surface contract

| Type | Role |
|------|------|
| `ChannelSurfacePlugin` | Capability record: outbound, threading, heartbeat, approvals, message-tool schema, streaming caps |
| `ChannelOutboundAdapting` | Render `MessagePresentation` and deliver via platform wire |
| `ChannelStreamingSurfaceSink` | `StreamingSurfaceSink` bridge during agent turns |
| `ChannelMessageOutputDeliverer` | `MessageOutputDelivering` registration for committed message-tool output |

Inbound trust, dedupe, session keys, and transport supervision live under [`Surfaces/Triggers/Channel`](../../Triggers/Channel/). Triggers assembles a full runtime `ChannelPlugin` from `ChannelSurfacePlugin` plus trigger slots at factory/registry time.

## Sibling surfaces

- [`Interface/Streaming/`](../Streaming/) — shared streaming engine, chunker, pacer
- [`Interface/TUI/`](../TUI/) — terminal transcript surface
- [`Interface/Commands/`](../Commands/) — slash/control input surface

## Related

- [`Surfaces/Triggers/README.md`](../../Triggers/README.md) — channel ingress and trigger dispatch
