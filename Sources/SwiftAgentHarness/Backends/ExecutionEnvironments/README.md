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

- **mode** — `off` / `non-main` / `all`
- **scope** — `agent` / `session` / `shared`
- **backend** — `local`, `docker`, `ssh`, `openshell`, `docker-browser`, …

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
| `ssh` | remote-canonical | seed-once remote root |
| `openshell` | mirror | `openshell` CLI; sync-before/sync-after via `WorkspaceMirrorSync` |
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

## Related

- Tool System dispatch: `ExecRuntimeService`
- Path confinement: `PathPolicy.swift`
- Lifecycle: `SandboxRuntimeRegistry`, `SandboxPruneService`
