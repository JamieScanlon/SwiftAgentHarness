# Execution Environments

Process-host backends the Tool System dispatches to for shell exec and filesystem bridge operations.

## Plugin shape

Each backend registers on a global registry with:

- **Manifest** — static `id`, `label`, `workspaceModel` (`host-canonical` / `remote-canonical` / `mirror`), `capabilities`
- **Factory** — `(CreateSandboxBackendParams) → SandboxBackendHandle`
- **Manager** — `describeRuntime`, `removeRuntime` (for persistent runtimes)

## Uniform runtime contract (`SandboxBackendHandle`)

- `buildExecSpec` — argv/env for one supervised exec (Tool System owns the supervisor)
- `runShellCommand` — short buffered shell for FS bridge ops
- `createFsBridge` — optional read/write/stat when workspace is not host-local
- `finalizeExec` — optional transport cleanup after exec (mirror sync-after)

## Configuration axes

Resolved by `SandboxConfigResolver`:

- **enabled** — master switch for using the configured persistent/remote backend (default `false`)
- **mode** — `non-main` / `all` (which sessions activate the configured backend when `enabled: true`)
- **scope** — `agent` / `session` / `shared`
- **backend** — `local`, `docker`, `ssh`, `openshell`, `docker-browser`, …

`sandboxingActive` on the resolved `SandboxConfig` means **use the configured persistent/remote backend**. It does **not** mean “skip Seatbelt/bwrap on the local backend.” When `sandboxingActive` is `false`, resolution falls back to the `local` backend; non-elevated exec on that backend is still wrapped when tooling exists.

| Setting | Effect on backend | Effect on local exec wrapping |
|---|---|---|
| `enabled: false` (default) | Forces `local` backend (`sandboxingActive=false`) | Still Seatbelt/bwrap when tooling exists |
| `enabled: true`, `mode: non-main`, main session | Forces `local` backend | Still Seatbelt/bwrap |
| `enabled: true`, `mode: non-main`, non-main session | Uses configured backend | Backend-specific sandbox |
| `enabled: true`, `mode: all` | Uses configured backend | Backend-specific sandbox |

### Config migration

`mode: "off"` is no longer supported. Use `"enabled": false` instead (equivalent backend-selection behavior). Decoding a config with `"mode": "off"` fails at load time.

### Host exec without sandbox

- Non-elevated `bash` on the `local` backend is **always** wrapped (macOS Seatbelt / Linux bwrap).
- **Full host exec** (`/bin/bash -c` without wrapper) is only via `elevated: true` on the bash tool, routed through `ElevatedExecHost` with approval policy.
- Exit **126** may auto-escalate per sandbox-denial policy (see below).

## Workspace models

| Model | FS bridge routing | Sync |
|---|---|---|
| `host-canonical` | `LocalHostFsBridge` | none |
| `remote-canonical` | backend handle bridge | backend-specific (SSH seed) |
| `mirror` | `LocalHostFsBridge` between turns | `WorkspaceMirrorSync` before/after exec |

## Built-in backends

| ID | Workspace model | Notes |
|---|---|---|
| `local` | host-canonical | macOS Seatbelt / Linux bwrap |
| `docker` | host-canonical | bind-mount workspace |
| `ssh` | remote-canonical | seed-once remote root; first connect records host keys to `~/.ssh/sah-known-hosts` (`StrictHostKeyChecking=accept-new`; changed keys rejected) |
| `openshell` | mirror | `openshell` CLI; mirror bind-mount at sandbox create; sync-before/sync-after via `WorkspaceMirrorSync` |
| `docker-browser` | host-canonical | separate Chromium container |

## Exec approval

- `ExecApprovalStore` — durable pending resolution keyed by approval UUID
- `ChannelExecApprovalDelivery` — posts approval cards on trigger channel surfaces (mock transport today)
- `/approve <id> [durable]` — CLI fallback resolution
- `POST /api/exec-approvals/:id` — REST resolution

### Sandbox-denial escalation

When a sandboxed `bash` call fails with exit code **126** (command found but not executable in the sandbox), the harness may automatically escalate to the elevated exec-approval path if the tool is listed in `toolPolicy.elevated.perCall` and the sender is allowlisted via `toolPolicy.elevated.allowFrom`. On approval, the command runs on the host via `ElevatedExecHost`. If escalation is unavailable, the tool returns an explicit error instead of a bare exit-126 message.

Classification lives in `SandboxBackendError.isSandboxExecDenial`; orchestration is in `WorkspaceFilesystemToolProvider.bash()`.

## Buffered vs supervised exec

| API | Use | Cancellation |
|---|---|---|
| `runSupervised` / `startSupervised` | Agent bash, background registry | `kill(-pgid, …)` tears down the whole tree |
| `run` | Docker/SSH FS bridge, rsync seed, container ensure | Local client only via `Process.terminate()` |

`runShellCommand` on Docker and SSH backends uses `run`. Cancelling a large remote `readFile` or interrupting an SSH seed may leave remote or in-container work running. That is acceptable for the short FS-bridge ops this path serves; agent exec uses the supervised path instead.

Background exec does not call `finalizeExec` today; mirror sync-after applies to foreground supervised exec only.

## OpenShell gateway setup

OpenShell sandboxes are auto-created per scope with the harness mirror directory bind-mounted at the configured `workdir` (default `/workspace`). Prerequisites:

1. Register and select a gateway: `openshell gateway add … --local --name local` then `openshell gateway select local`
2. Enable bind mounts for the active compute driver in `gateway.toml` (e.g. `[openshell.drivers.docker] enable_bind_mounts = true`, or the Podman equivalent)
3. Ensure the `openshell` CLI is on `PATH` (`/opt/homebrew/bin/openshell`, `/usr/local/bin/openshell`, or `/usr/bin/openshell`)

The harness rsyncs host workspace → mirror before exec and mirror → host after exec (including failed commands). Sandbox exec writes land in the mirror via the bind mount.

## Related

- Tool System dispatch: `ExecRuntimeService`
- Path confinement: `PathPolicy.swift`
- Lifecycle: `SandboxRuntimeRegistry`, `SandboxPruneService`
