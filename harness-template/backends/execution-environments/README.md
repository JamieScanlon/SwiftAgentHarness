# Execution Environments

## TL;DR

An **execution environment** is a plugin that knows how to run a process somewhere — its workdir, its filesystem view, its env, its supervisor. Execution environments are **not** the unit of tool invocation (the [Tool System](../../core/tool-system/) is); they are **process-host backends** the Tool System dispatches to. Treat each environment as a self-contained extension with a static manifest, a runtime factory that returns a `SandboxBackendHandle`-shaped contract, and a small set of operations the Tool System calls into.

The prescriptive shape:

1. **Mode × scope × backend** as three orthogonal configuration axes — *when* to sandbox (`off`/`non-main`/`all`), *how many* containers (`agent`/`session`/`shared`), and *which runtime* (`docker`/`ssh`/`openshell`/...). 
2. **Backend registry** as the dispatch primitive — a named `SandboxBackendFactory` registered on a process-global map, with a `SandboxBackendManager` for lifecycle (`describeRuntime`, `removeRuntime`).
3. **`SandboxBackendHandle` as the single uniform interface** — `id`, `runtimeId`, `workdir`, `buildExecSpec(...)`, `runShellCommand(...)`, `finalizeExec?`, `createFsBridge?`. Tool System sees one shape; backends ship one implementation.
4. **Three workspace-canonicality models** — *host-canonical* (Docker bind-mount or local), *remote-canonical* (SSH seed-once), and *mirror* (OpenShell sync-before-and-after-exec). Each implies different file-tool semantics; document the choice. 
5. **Filesystem confinement at the runtime seam, not at every call site** — a `path-policy` module rewrites every tool-supplied path into a relative workspace path or rejects it; symlink/hardlink escapes resolve to deepest existing ancestor and re-check. 
6. **A single supervised process registry for background work** — `bash-process-registry` tracks long-running PIDs with TTL, log buffer, exit notification, abort token. Foreground vs background is a flag on the bash tool, not two tools.
7. **Escape hatches as a typed concept, not an env-var override** — *elevated mode* runs a sandboxed agent's exec on the host via a configured `escape path` (`gateway` by default, `node` for paired node hosts), with allowlist gating per surface. 
8. **Approval gates live at the exec layer, not in the tool runner** — `bash-tools.exec-approval-request.ts` and `bash-tools.exec-approval-followup.ts` implement the loop; approvals can defer to native UI cards (Slack/Discord/Teams) and fall back to `/approve`. (See also [Tool System permission model](../../core/tool-system/).)

This is the recommended design. The right programming model: one abstract base with `_run_bash()` + `cleanup()`, concrete implementations per backend, a uniform `execute()` wrapper that handles snapshot-sourcing, CWD persistence, and interrupt handling. The right registration shape: typed plugin manifest, factory function, optional manager, registered by name. The right minimal seam: three callbacks (exec, readFile, writeFile) any extension can stub to delegate to anywhere. A single-binary single-host design is the *non-default* — it works for an IDE-coupled coding agent but breaks the moment you want multi-tenancy, untrusted code, or remote execution. Delegating the sandbox primitive to an Anthropic-supplied tool is a viable point on the design space — at the cost of inheriting that tool's capabilities.

For the layer that *uses* execution environments, see [`../../core/tool-system/`](../../core/tool-system/). For the persistence backend the registry writes to, see [`../persistence/`](../persistence/). For the trigger surfaces that can drive exec without a human (cron, channel arrivals), see [`../../surfaces/triggers/`](../../surfaces/triggers/).

---

## How this fits the architecture

The architecture lock-in puts the [Tool System](../../core/tool-system/) as the single sanctioned path to side-effects. That commits us to a specific layering — the question this page answers is what *exactly* an execution environment is, given that the Tool System sits above it.

### The four-layer split

Separate four orthogonal concerns — this resolves a category error that most harnesses conflate somewhere:

| Layer | What it owns | Example values |
|---|---|---|
| **Tool** | Tool schema, model-facing description, validation, approval | `exec`, `read`, `write`, `edit`, `apply_patch`, `process` |
| **Backend** | Process host, workspace mount, runtime label, exec-spec construction | `docker`, `ssh`, `openshell`, `local`, `modal`, `daytona`, `singularity` |
| **Workspace model** | Canonicality (host / remote / mirror), sync policy | `bind-mount`, `remote-canonical`, `mirror`, `none` |
| **Trigger** | What initiated the exec | CLI message, slash command, channel arrival, cron, webhook |

The product of these is the addressable thing. `exec + docker + bind-mount + slack-channel-arrival` is unambiguous; `process + ssh + remote-canonical + cron` is a different addressable. None of the four is reducible to another. Folding backend, workspace model, and trigger into a single `spawn(...)` call collapses three concerns into one — and pays for it the moment you want a single agent process to drive both a local Docker sandbox and a remote SSH host. An ABC that inherits the workspace model into the backend rather than treating it as orthogonal ends up with a `file_sync.py` that is essentially "Docker has bind-mount, SSH/Modal/Daytona use mirror" — the orthogonality is lost.

### What lives here vs. on Tool System

The [Tool System](../../core/tool-system/) commits us to: *"Backends live inside the dispatch fabric — they translate 'this tool wants to run this command' into 'this backend's exec spec.' Nothing else in the harness should know about backends."* That's the boundary.

This page covers the **plugin shape** — what an execution-environment backend *is*, what hooks it exposes, what its manifest declares, how it's discovered. Concerns that *use* backends but don't live in them go on the Tool System page:

| Concern | Owner | Why |
|---|---|---|
| Backend plugin manifest, file layout, registration | **Execution Environments (this page)** | Static shape of the backend |
| Container/SSH/process lifecycle (create / describe / remove / prune) | **Execution Environments (this page)** | Per-backend mechanics |
| `SandboxBackendHandle` contract (`buildExecSpec`, `runShellCommand`) | **Execution Environments (this page)** | The runtime seam |
| Path policy (workspace-relative rewrite, escape rejection) | **Execution Environments (this page)** | Per-workspace fact |
| Tool routing (which backend to dispatch to) | **Tool System** | Cross-tool decision |
| Tool approval (`requireApproval`, headless denial) | **Tool System** | Cross-tool policy |
| Background process registry | **Execution Environments (this page)** | Per-process state |
| Foreground vs background flag on the bash tool | **Tool System** | Tool-schema concern |
| FS-write atomicity (queued writer, session lock) | **Execution Environments (this page)** | Per-file fact |
| FS-read truncation, encoding handling | **Tool System** | Tool-output shape |
| Elevated/escape-path resolution | **Execution Environments (this page)** | Per-backend semantics |
| Surface allowlist for elevated (which Slack user, which Discord ID) | **Tool System** + [Triggers](../../surfaces/triggers/) | Cross-surface decision |

The split holds because each row is a different temporal scope. Backends describe a *frozen contract* (workspace mount, exec-spec shape, supervisor). The Tool System consumes that contract at *runtime* (which backend to dispatch to, which approval to request, what to log). Mixing the two makes both impossible to test in isolation.

### Execution environment as a backend, not a surface

An execution environment is **never** a top-level architectural concept on the same plane as the Tool System or the Conversation Manager. It is a backend the Tool System drives, in the same family as persistence backends (under the Conversation Manager / Memory) and provider backends (under the Model Pool). The naming is deliberate: `harness-template/backends/execution-environments/` lives next to `backends/persistence/` and `backends/providers/` because all three are *drivers* the inner ring uses.

The corollary: an execution-environment plugin should never spawn its own runtime, own its own conversation state, expose its own UI surface, or implement its own tool schema. If a "backend" needs to do those things, it's not a backend — it's an *agent runtime* (and belongs in the Sub-Agent Pool's transport adapters) or a *trigger surface* (and belongs in [Triggers](../../surfaces/triggers/)).

---

## What an execution-environment plugin owns

The unit of code on disk. The structure below is what the recommendations in [§Recommendation](#recommendation) assume; the manifest is statically validatable and inspectable without executing plugin code.

### Plugin layout on disk

```
extensions/<backend>/
  plugin.json                 # static manifest — schema-validated
  index.ts                   # plugin entry, definePluginEntry()
  backend.ts                 # factory: (params) => SandboxBackendHandle
  manager.ts                 # lifecycle: describeRuntime, removeRuntime
  config.ts                  # config-shape resolution from agent + global
  fs-bridge.ts               # optional — file ops over the backend transport
  onboard.ts                 # optional — onboarding (SSH key setup, daemon check)
```



### The manifest

Static, schema-validated, no code execution at load. Keys borrowed from the provider-plugin manifest shape, adapted for execution environments:

```jsonc
{
  "id": "ssh",
  "label": "SSH",
  "sandboxBackends": [
    {
      "id": "ssh",
      "label": "SSH-accessible host",
      "workspaceModel": "remote-canonical",
      "capabilities": {
        "browser": false,
        "bindMounts": false,
        "persistentRuntime": true
      },
      "configSchema": "./schema/ssh-config.json"
    }
  ],
  "uiHints": {
    "iconRef": "ssh-mark",
    "category": "remote"
  }
}
```

Three properties of this shape worth being explicit about:

1. **`workspaceModel` is declarative**, not derived at runtime. The Tool System needs to know whether file tools should write directly (host-canonical) or through the bridge (remote-canonical / mirror) before it dispatches. Declaring it in the manifest avoids per-call branching.
2. **`capabilities.browser` is a backend-level flag**, not a separate plugin slot. Only Docker and (eventually) Singularity can host a sandbox browser today; SSH and OpenShell cannot. The flag is what the [Tool System](../../core/tool-system/) reads to gate the `browser` tool.
3. **`capabilities.persistentRuntime` is *the* knob** for whether prune / lifecycle / max-age applies. Local execution and modal-ephemeral don't have persistent runtimes; Docker, SSH, Daytona do. Manage them with the registry; ignore the others.

### The runtime contract

What `backend.ts` exports — the factory and the `SandboxBackendHandle` it returns.:

```ts
type SandboxBackendFactory = (params: CreateSandboxBackendParams) => Promise<SandboxBackendHandle>

type CreateSandboxBackendParams = {
  sessionKey: string
  scopeKey: string                  // collapses session→scope (per agent or shared)
  workspaceDir: string              // host path to the workspace root
  agentWorkspaceDir: string         // host path to the agent's data
  cfg: SandboxConfig                // resolved config — see § Configuration
}

interface SandboxBackendHandle {
  id: SandboxBackendId              // matches the registered name
  runtimeId: string                 // stable handle (container name, ssh runtime id)
  runtimeLabel: string              // human-readable
  workdir: string                   // initial cwd inside the runtime
  env?: Record<string, string>
  configLabel?: string              // image / ssh target / openshell sandbox name
  configLabelKind?: string          // "Image" | "BrowserImage" | "Target" | ...
  capabilities?: { browser?: boolean }

  // The core seam: build the argv + env for *one* exec invocation
  buildExecSpec(params: {
    command: string
    workdir?: string
    env: Record<string, string>
    usePty: boolean
  }): Promise<SandboxBackendExecSpec>

  // Cleanup hook for exec finalize (close SSH session, etc.)
  finalizeExec?: (params: {
    status: "completed" | "failed"
    exitCode: number | null
    timedOut: boolean
    token?: unknown
  }) => Promise<void>

  // Direct shell escape — for FS bridge ops that don't need full supervisor
  runShellCommand(params: SandboxBackendCommandParams): Promise<SandboxBackendCommandResult>

  // Optional: the FS bridge for read/write/edit when workspace isn't local
  createFsBridge?: (params: { sandbox: SandboxFsBridgeContext }) => SandboxFsBridge
}

interface SandboxBackendManager {
  describeRuntime(params): Promise<SandboxBackendRuntimeInfo>   // is it running? does config match?
  removeRuntime(params): Promise<void>                          // for `sandbox recreate` / prune
}
```

The shape is a deliberate inversion of the conventional "`DockerBackend extends BaseBackend` with virtual `exec()`" layout. Backends answer questions; they don't run the loop. The Tool System calls `buildExecSpec` to get an argv, runs it itself with its own supervisor, and calls `finalizeExec` when done. Stateless except for the per-runtime cache (which the registry owns).

What is **not** on this contract, by design: command parsing, output truncation, retry policy, approval flow, model-facing description. Those are the Tool System's job. The clean separation is what makes the same supervisor reusable across Docker / SSH / OpenShell / local without branching.

---

## Recommendation

### Mode × scope × backend as orthogonal axes

The most consequential factoring decision. Three independent axes; treat them that way:

- **mode** controls *when* sandboxing applies: `off` (never), `non-main` (only non-primary sessions — group chats, channel rooms, sub-agents), `all` (every session).
- **scope** controls *how many* runtimes get created: `agent` (one per agent), `session` (one per session — highest isolation), `shared` (one for all sandboxed sessions — cheapest).
- **backend** controls *which* runtime hosts the exec: `docker` (default when enabled), `ssh`, `openshell`, and plugin-supplied backends (`modal`, `daytona`, `singularity`, etc.).

The defaults that matter:

- **`mode: "non-main"`** is the right default if you accept any non-CLI surface. The operator's own DM (the "main" session) runs on the host where they can `ls` afterwards; group chats, channel mentions, and cron-driven turns run sandboxed. The reasoning: trust originates with the operator and degrades for non-operator-initiated work. (This is also why [Triggers](../../surfaces/triggers/) classifies non-user content into trust levels — same principle, different layer.)
- **`scope: "agent"`** is the right default. Per-session is too expensive (one container per Slack thread is a non-starter on a laptop); shared is too leaky (one session's `rm -rf` poisons every other session). One container per agent is the sweet spot.
- **`backend: "docker"`** is the right default when sandboxing is enabled. Local, fast, well-understood security model, supports a browser sandbox. SSH and OpenShell are for offloading; reach for them when the host can't host a Docker daemon (cloud Gateway deployments, mobile pairing) or when you want a managed remote sandbox.

The factoring matters because **conflating these axes leads to per-backend-per-mode-per-scope code** — the matrix expands multiplicatively and no two backends end up implementing the same logic the same way. Keep them orthogonal; let the config resolver merge them; let the backend factory consume a single `SandboxConfig`.

The config resolver returns a fully-resolved `SandboxConfig` from `(globalConfig, agentId)`. Backends never see raw config — they see the merged shape.

### `SandboxBackendHandle` as the single uniform interface

The most useful single piece of design: a `SandboxBackendHandle` typed contract that every backend must satisfy.

The contract has two operations that look similar but serve different needs:

- **`buildExecSpec(...)`** returns an `argv` + env + stdin-mode for *one* foreground or background tool-call exec. The Tool System's supervisor runs the argv itself, captures output, handles approvals, integrates with the bash-process-registry. The backend doesn't run the process; it builds the spec.
- **`runShellCommand(...)`** runs *one* short, fully-buffered shell command end-to-end inside the backend. This is what the FS bridge uses for `stat`, `mkdir -p`, `rm`, `cat | tee`, etc. The result is `{ stdout: Buffer, stderr: Buffer, code: number }`. No supervisor, no approval, no streaming.

The split matters because the tool-call exec needs streaming, PTY mode, abort, timeout, log buffer, approval — all things the Tool System owns. The FS bridge ops are short, predictable, and need to share the backend's transport (SSH connection, container) without rebuilding it. Two operations, two purposes.

The other key field is `finalizeExec?`. For backends that pool a transport per call (SSH spawns a session in `buildExecSpec`, openshell does the same), the Tool System calls `finalizeExec` after the exec completes so the backend can dispose. Local / Docker backends don't need it; they leave it unset.

### Workspace-canonicality as a declared property

There are three workspace models, and the choice cascades into how every file tool behaves:

| Model | Source of truth | When to use |
|---|---|---|
| **Host-canonical** | Host filesystem | Local exec, Docker bind-mount, OpenShell `mirror` mode (between turns) |
| **Remote-canonical** | The backend's own filesystem | SSH (seed-once-then-canonical), OpenShell `remote` mode, Modal/Daytona ephemeral sandboxes |
| **Mirror** | Host between turns, backend during turn | OpenShell `mirror` mode (sync-before, sync-after) |

The choice has user-visible consequences and should be explicit in the manifest. The big ones:

- **File tools' write semantics differ.** Host-canonical: `write` is `fs.writeFile(hostPath)`, immediate. Remote-canonical: `write` is `runShellCommand({script: 'cat > "$1"', args: [remotePath], stdin: content})`. Mirror: write is host-canonical at the file-tool boundary, then sync runs before exec.
- **Read for prompt media differs.** Host-canonical: pass the host path to the model SDK. Remote-canonical: stage the file to a local temp dir first.
- **Skills loading differs.** Host-canonical: skills are read from the workspace. Remote-canonical: skills are mirrored into the sandbox workspace (`.../skills`) and read from there.

The recommendation: **declare the model in the backend manifest**, route file-tool dispatch through an FS bridge that knows it, and never let any tool branch on "what backend is this?" at the call site.

The bridge contract is small. The `SandboxFsBridge` exposes `stat`, `readFile`, `writeFile`, `mkdir`, `rename`, `remove` — all implemented on top of `runShellCommand`. A Docker backend's bridge is a thin shell around `docker exec`; an SSH backend's bridge is the same shell around `ssh ... bash -c`; the file tool sees the same operations either way.

### Filesystem confinement at the runtime seam

Path safety is *not* a per-tool concern. If `read` checks workspace-relative paths and `write` doesn't, you have a bug waiting to happen. Centralize at one place — call it `path-policy` — and route every tool-supplied path through it.

Export `toRelativeWorkspacePath(root, candidate, options?)` and `toRelativeSandboxPath(root, candidate, options?)` from a single path-policy module. Throw with a `Path escapes ${boundary}` message when the candidate resolves outside the boundary, after symlink resolution (walk the deepest existing ancestor through `realpath`).

Three rules to internalize:

1. **Relative paths are always anchored to the agent workspace root** — not the tool's `cwd` argument, not the user's home. If a user-supplied `cwd` resolves outside the workspace root, the tool rejects.
2. **Symlinks are resolved at the deepest existing ancestor.** A symlink that points outside the workspace fails closed even if the leaf does not exist yet. Example: `/workspace/run-link/new-file` still resolves as `/var/run/...` if `run-link` points there — symlink-parent escapes fail closed even when the final leaf has not been written.
3. **Bind-mount sources are normalized the same way.** `agents.defaults.sandbox.docker.binds` is validated against an allowlist after canonicalization, so a bind that points into the allowlist via a symlink-to-elsewhere is still rejected. Reference: same doc section.

The corollary anti-pattern is *per-tool* path validation. If `read.ts`, `write.ts`, `edit.ts`, and `apply_patch.ts` each grow their own `if (!isUnderWorkspace(p))` check, the rule lives in N places and drifts. The runtime makes it correct either way.

### Filesystem atomicity: queued writer + session lock

Two scenarios that bite production agents and are both fixable with one primitive each:

**Concurrent writes to log files.** When multiple tool calls (or sub-agents) write to the same transcript or trace log, `fs.appendFile` interleaves bytes mid-line. `getQueuedFileWriter(path)` returns a singleton writer that:

- Queues writes through a single async dispatcher.
- Opens the file with `O_NOFOLLOW` (refuses symlinks).
- Verifies the post-open `lstat` matches the pre-open `lstat` (refuses TOCTOU swap).
- Refuses hardlinked targets (`nlink > 1`).
- Refuses non-file targets.

This is *file safety*, not concurrency — most harnesses get the safety pieces wrong and don't realize it until they're exfiltrating data through a symlinked attacker-supplied log path.

**Concurrent writers across processes.** When the same agent is touched by two processes (rare but real: an editor's LSP integration + the CLI), atomic JSON updates need cross-process locks. `acquireSessionWriteLock(path, {maxHoldMs, staleMs})`:

- File-based, process-aware (writes `{pid, createdAt, starttime}` to a `.lock` sidecar).
- Detects stale locks via PID liveness check + age threshold.
- Non-reentrant by default (caller opts into reentrancy explicitly).
- Watchdog removes orphaned locks on a timer.

If you don't need cross-process atomicity, an in-process mutex around `queued-file-writer` is enough. If you do (and IDE integration paths usually do), `session-write-lock` is the right shape.

The Tool System should *never* see these. They're internal to the FS bridge and the persistence layer.

### Long-running processes: one supervised registry

Background processes are the most error-prone surface in any agent harness. One in-memory registry keyed by session-slug:

- **TTL bounded** (default 30 min, clamped to [1 min, 3 hours]). Stale entries get reaped automatically.
- **Output buffered** with separate `pendingStdout`, `pendingStderr`, `aggregated`, `tail` slots — the model gets back what's new since last poll, the registry keeps a bounded total.
- **Backgroundable mid-run.** The recommended behavior is to *background a foreground exec that exceeds the assistant-mode blocking budget* — that 2-minute (configurable) bound prevents an exec from blocking the conversation indefinitely. The exec keeps running; the model gets a `backgroundTaskId` and uses `BashOutput`/`process` to poll.
- **PTY-aware.** Cursor key mode (`smkx`/`rmkx`), paste encoding (`bracketed paste`), keystroke buffering — all live on the session struct.
- **`process` tool inspects; `process_send_keys` writes stdin.** Two tools, not one — `process` is the read-side (logs, status, kill); `process_send_keys` is the write-side (typing into a REPL, answering an interactive prompt).
- **`cron` for future scheduling, not exec polling.** The system prompt explicitly tells the model: *"Use `cron` for future follow-up; don't use `exec` sleep loops or repeated `process` polling."* This is a tool-design decision but it lives in the registry's gravitational field; document it.

The anti-pattern: a separate "shell session" tool that maintains its own persistent shell. This results in a different concurrency model in the foreground tool vs. the background tool — easy to break, hard to debug. One registry, one supervisor, one tool with a `run_in_background` flag.

### Escape hatches: elevated mode as a first-class type

When sandboxing is on, the model often needs to escape *for one specific command*: `docker ps` (the host's Docker, not the sandbox's), `apt install` (on the host), `git push` to a credential the sandbox can't see. Without a typed escape hatch, agents grow ad-hoc `tools.exclude` lists and per-command rules.

Treat elevation as a session-scoped *mode* with three levels:

- **`/elevated on` (or `ask`)** — exec runs outside the sandbox; approvals still apply.
- **`/elevated full`** — exec runs outside the sandbox; approvals are skipped.
- **`/elevated off`** — back to sandboxed exec (default).

The escape path is configurable per backend: by default `gateway` (the host process running the Gateway), or `node` when a paired companion-app node host is present and the session's exec target is `node`.

Two design choices worth borrowing verbatim:

1. **Per-sender allowlist.** `tools.elevated.allowFrom: { discord: ["user-id-123"] }` — elevation requires both the agent to be in an elevated mode *and* the sender to be on the allowlist. The two checks are independent because the sandbox boundary is about *what the agent can do*, and the elevation boundary is about *who can authorize the escape*.
2. **Inline directives.** `/elevated full run the deployment script` applies elevation to *that message only*, not the session. Useful for one-off escapes without leaving the session elevated. Reference: same doc, "Resolution order".

The anti-pattern: leaving the sandbox via env-var override (`SANDBOX_DISABLED=1`) or a `dangerouslyDisableSandbox` per-tool flag. Such a flag without a session/sender allowlist machinery lets the model request it without an out-of-band approval. Pair the flag with elevation, or it becomes a security hole.

### Approval flow at the exec layer

Approvals belong at the exec boundary, not in the tool runner. Wire three pieces together at the exec boundary:

1. **`requireApproval` classification** by `exec-approvals.ts` — given a command, security level, and ask mode, returns whether approval is needed (and what kind).
2. **Native-UI deferral** — if the trigger is a Slack message, the approval card renders in Slack with Approve/Deny buttons. If Discord, Discord buttons. If Teams, an Adaptive Card. If headless (cron), the request fails with a *headless denial* error message that names the missing approval.
3. **Fallback to `/approve`** — when native UI isn't available, the user types `/approve <id>` in the next turn. The approval state is durable (`addDurableCommandApproval`), so the same command issued again is pre-approved.

The split between *classification* (Tool System) and *delivery* (Execution Environments) holds because:

- Classification is pure: a command string + a security level → a decision. No I/O.
- Delivery is per-surface: Slack/Discord/Teams have different UI primitives, and headless mode (cron, trigger-driven turns) has no UI at all.

The approval is requested once; the follow-up notification (delivered back to the channel where the approval was sent) happens at the same layer.

The anti-pattern: per-tool `permission_required: true` flags with no centralization. Every tool grows its own approval-request code and they all diverge.

### Backend pruning, lifecycle, and the registry

Long-lived containers leak. Stale SSH workspaces accumulate. The reference design is a JSON registry keyed by sandbox runtime, with prune rules per backend:

- **`SandboxRegistry`** — list of `{containerName, sessionKey, createdAtMs, lastUsedAtMs, image, configHash}`. Persisted to JSON, atomic-write through `writeJsonAtomic`, gated by `session-write-lock`.
- **Prune knobs** — `idleHours` (default depends on backend), `maxAgeDays`. Stale runtimes get cleaned up by `sandbox prune` (manual or cron-driven).
- **`configHash`** lets the manager detect "this runtime was created with old config" and offer to recreate.
- **Per-backend manager** (`describeRuntime`, `removeRuntime`) handles backend-specific lifecycle: Docker removes the container; SSH removes the per-scope remote root; OpenShell calls `openshell sandbox delete`.

The recommendation: **make the registry backend-agnostic** (the entry shape is the same for all backends) but the manager backend-specific. 

The reason the registry is per-backend at lookup time: the `containerName` field for Docker is opaque (e.g. `sandbox-<hash>`), but for SSH it's the per-scope remote root path. Same entry shape, different content semantics. The manager interface (`describeRuntime`/`removeRuntime`) papers over the difference.

### Browser sandbox as a separate container

If the harness supports a browser tool, it gets its own container. Run it on its own Docker network (isolated from the general-purpose sandbox network), with an optional `cdpSourceRange` CIDR allowlist for container-edge CDP ingress.

Three properties worth borrowing:

1. **noVNC observer access is password-protected** with short-lived tokens. The password is in the URL fragment, not the query string or header logs.
2. **`allowHostControl` is per-agent**, defaulted false. When true, sandboxed sessions can target the host browser explicitly via `target: "host"` on browser-tool calls; otherwise they're confined to the sandbox browser. Reference: same doc.
3. **The browser image is independent.** `agents.defaults.sandbox.browser.image` is configured separately from `agents.defaults.sandbox.docker.image`. Same registry, two images.

The anti-pattern is conflating the exec sandbox image with the browser sandbox image. Browsers need GPU pass-through, Chromium dependencies, larger disk; exec sandboxes need a minimal Debian. Different containers, different lifecycles.

### Local execution as a degenerate backend

The harness must be runnable without Docker, for development and for "just on my laptop" use cases. The right shape: local execution is **a backend like any other** — same `SandboxBackendHandle` contract, same registry shape, just with a no-op container layer.

`LocalEnvironment` extends the same `BaseEnvironment` ABC as Docker / SSH / Modal / Daytona / Singularity. The base class's `_wrap_command(...)` does the env-snapshot sourcing and CWD-marker emission regardless of backend; `_run_bash(...)` on Local is a direct `subprocess.Popen` with `os.setsid` (kill-the-process-group on abort).

Two pieces specifically worth borrowing from the local-backend design even if the rest of the design is different:

1. **`os.setsid` + kill-the-process-group on abort.** Without it, backgrounded grandchildren (`cmd & disown`) survive the parent's abort as orphans (reparented to init). The local backend's `_kill_process` overrides the base to send `SIGTERM` to the whole process group, not just the immediate child.
2. **Stdout drain via `select()`, not `for line in proc.stdout`.** The `for line` pattern blocks until EOF, which never happens if a grandchild inherited the pipe. `select()` with a short poll + idle-after-bash-exit threshold makes the drain return promptly when bash exits even if grandchildren still hold the write end. This is the kind of bug you only find in production; borrow the fix.

The corollary: **don't make "local" a special case at the call site.** If file tools branch on `if (backend === "local") writeFile else runShellCommand`, the local path stays under-tested. The right answer: one base class, concrete backends, no branching at call sites.

### Remote backends: snapshot + sync vs. SSH ControlMaster

For remote execution (SSH, Modal, Daytona) two design choices matter:

**Session snapshot vs. persistent shell.** A persistent SSH shell is intuitive but fragile (network blips kill it, reconnection breaks history). The reference design is **spawn-per-call with a snapshot file**: at session init, capture env vars + functions + aliases into a remote file; before each command, `source` the snapshot and `cd` to the persisted CWD. The snapshot is just text; it survives reconnection, multiple processes can append concurrently (last-writer-wins), and there's no held connection to lose.

**SSH ControlMaster for connection persistence.** Spawn-per-call doesn't mean spawn-a-new-SSH-handshake-per-call. ControlMaster lets one persistent control connection multiplex many command channels. The socket path needs to be short (macOS enforces a 104-byte `sun_path` limit), so hash the `user@host:port` triple to keep it stable across reconnects.

**File sync for remote-canonical backends.** SSH/Modal/Daytona need credential files + skills + cache mirrored into the sandbox. A `FileSyncManager` tracks `(host_path, remote_path)` pairs by `(mtime, size)`, uploads only changes, and runs as a `_before_execute` hook on the backend.

The corollary anti-pattern: a different sync strategy per backend. Share one `FileSyncManager` across SSH, Modal, and Daytona backends — a single sync strategy shared via `createRemoteShellSandboxFsBridge`.

---

## Alternatives

### Single local binary, no backend abstraction (single-binary CLI alternative)

A single-binary CLI ships one bash tool, one file-write tool, one file-edit tool, all running directly on the host as the user. The "sandbox" is a local sandbox runtime package — an OS-level capability sandbox (sandbox-exec on macOS, bubblewrap on Linux) that wraps the spawned subprocess. There is no backend abstraction; the choice is sandbox-on or sandbox-off, on the local host.

**When this works:** when the harness is single-user, single-host, single-tenant — an IDE-coupled coding agent where the user *is* the operator and the workspace *is* their repo checkout. The reduction in surface area (no backend registry, no FS bridge, no remote canonicality) is real and the sandbox-runtime primitive is a solid security boundary. A `dangerouslyDisableSandbox` escape hatch per-command can exist for known-safe escapes, with model-side prompts discouraging gratuitous use.

**Why not as default:** the moment you want multi-tenancy (one Gateway, many users), a non-local target (offload to a beefy SSH host, run in a managed sandbox), or untrusted code (a chat-based agent in a Slack workspace where any member can DM it) — there's nowhere for the backend choice to go. The runtime has to grow a per-call dispatch path, which is where the `SandboxBackendHandle` shape comes from anyway. This design works *because* it is deliberately a coding tool for the operator; most harnesses aren't in that position.

**A local sandbox runtime package as the local-backend implementation** is worth adopting regardless of architecture. The package itself is a viable choice for the "local" backend's enforcement layer; An inline-bash example can use the same primitive. The package is more than just a `subprocess.spawn` wrapper — it ships seccomp-like filesystem and network restrictions per call, which is real safety even on a host-canonical local backend.

### Six-backend ABC with shared base class

Six terminal backends (`local`, `docker`, `ssh`, `modal`, `daytona`, `singularity`) all extend a single `BaseEnvironment` ABC. The base class handles snapshot sourcing, CWD persistence, interrupt handling, stdout draining, timeout enforcement; subclasses implement `_run_bash()` + `cleanup()`. Selection is by `TERMINAL_ENV` env var.

**When this works:** when the harness is comfortable with one programming idiom for all backends (Python ABC + abstract `_run_bash`) and the backends share enough lifecycle to make the base class earn its keep. These six backends really do share more than they differ — they all spawn a fresh bash per call, source a snapshot, persist CWD via stdout markers, handle the same interrupt protocol. The ABC is doing real work.

**Why not strictly as default:** the ABC conflates *the backend* (how to spawn a process) with *the workspace model* (how files get there). Bind-mount backends (Docker, Singularity, Local) skip `FileSyncManager`; remote-canonical backends (SSH, Modal, Daytona) use it. That fork lives inside individual backend classes rather than as a declared property of the manifest — which works for six backends but doesn't scale to plugin-supplied backends that the harness can't see at build time.

The piece worth borrowing: **the `BaseEnvironment` interface itself.** `init_session` → `execute(command, cwd, timeout, stdin_data) -> {output, returncode}` + `cleanup()` is the right minimum. Pair with the typed `SandboxBackendHandle` (more methods than that base requires, but the same shape) and you get the best of both — declarative manifest for backend selection, programmatic interface for backend implementation.

The other piece worth borrowing: the **`_ThreadedProcessHandle` adapter**. Modal/Daytona expose blocking SDK calls; the adapter wraps `exec_fn() → (output, exit_code)` in a thread and exposes a `ProcessHandle`-compatible interface (`poll`, `kill`, `wait`, `stdout`). This is the right shape for SDK-style backends that don't ship a real `Popen`.

### `BashOperations` + extension-friendly remote ops

A minimal local-only bash tool with a typed `BashOperations` interface that extensions can override. An SSH extension (~100 lines) overrides `BashOperations`, `ReadOperations`, `WriteOperations`, `EditOperations` to delegate to `ssh user@host`.

**When this works:** when the harness wants a *minimal* execution layer and the production deployment will ship extensions for any non-local backend. This is the right scope for a coding agent library. Extensions own the backend choice; the core stays small.

**Why not strictly as default:** the manifest-less extension model means a plugin's declaration of "I provide bash for SSH" lives in `ExtensionAPI.registerTool('bash', ...)` calls rather than a typed manifest. There's no offline `backends inspect` — you have to run extension code to find out. Workable for a library; doesn't scale to a plugin marketplace.

The piece worth borrowing: **the `BashOperations` interface as the minimum.** `exec(command, cwd, {onData, signal, timeout, env}) → Promise<{exitCode}>` is the irreducible core, smaller than `SandboxBackendHandle`. For prototyping a new backend, start here; once it's working, lift to the full manifest shape.

### Filesystem-backed sandbox protocol

A `SandboxBackendProtocol` with operations for ls, glob, grep, read, write, edit, execute, upload_files. Concrete subclasses (`LocalShellBackend`, `BaseSandbox`) implement `execute()` + `upload_files()`; everything else is derived from those via shell commands. The `LocalShellBackend` explicitly warns that it provides "no sandboxing or isolation" and uses HITL middleware as the safeguard.

**When this works:** when the harness is committed to a graph-executor framework and benefits from operations being defined at the protocol level rather than per-tool. The over-derivation (every operation is `execute()` of a shell command) is sound for a remote sandbox where one round-trip is the unit of cost.

**Why not strictly as default:** the protocol conflates *filesystem* and *exec*. The same backend implements `read`, `ls`, `glob`, `grep`, `execute`, `upload_files` — which means the abstract test surface is huge, and a backend that's good at one operation isn't necessarily good at all of them. The split in this page (`buildExecSpec` for tool-call exec; `runShellCommand` for FS-bridge ops; `createFsBridge` for higher-level fs operations) keeps the slices independent.

The piece worth borrowing: **a `LocalShellBackend` with explicit HITL framing.** The right tone in the manifest — "this backend grants the agent unrestricted shell execution; use HITL middleware as your primary safeguard." Most harnesses ship a local backend without the warning and the user assumes more isolation than there is. Lift the warning into the manifest; surface it in `inspect`.

### `srt` sandbox-runtime CLI as a single primitive

This pattern delegates to `srt` (a sandbox-runtime CLI). The adapter checks `shutil.which("srt")` at runtime; if present, every shell command is wrapped via `srt run --settings ... -- <cmd>`.

**When this works:** when a vendor-supplied sandbox primitive already does what you need (filesystem allow/deny, network allow/deny, platform-aware policy) and the harness does not want to maintain its own backend code.

**Why not strictly as default:** the bus factor is one; if the vendor tool's capabilities do not grow to cover what the harness needs, the harness has nowhere to go without forking. Also, it may be local-only — there may be no remote-canonical workspace model.

The piece worth borrowing: **the settings-to-payload converter shape.** `build_sandbox_runtime_config(settings: Settings) -> dict` is a clean adapter pattern — internal config types in, JSON the external tool expects out. Whether the external tool is `srt` or a Docker SDK or an SSH library, the adapter shape stays the same.

---

## Anti-patterns

- **Backend selection as a runtime env-var or string switch.** `if TERMINAL_ENV == "docker" else if "ssh" else ...` (workable for a fixed set of built-ins but does not extend to plugin-supplied backends) buries the dispatch decision in a function. The right primitive is a typed registry: backends register by name (`registerSandboxBackend("docker", {factory, manager})`), the resolver picks the registered factory, the call site stays open.

- **`SandboxBackend.execute()` as the only operation.** A backend with just `execute(command) → output` can't host a file bridge, can't be queried for runtime state, can't be pruned. The `SandboxBackendHandle` shape with `buildExecSpec` + `runShellCommand` + `finalizeExec` + `createFsBridge` + `manager.{describeRuntime, removeRuntime}` separates the concerns explicitly. Tools can use one operation without the others; backends don't have to implement everything.

- **Workspace canonicality inferred from the backend name at the call site.** `if (backend === "ssh") { /* remote-canonical */ } else { /* host-canonical */ }` at any file-tool implementation is a smell. Declare canonicality in the manifest; route through an FS bridge that knows it; let the file tool stay backend-agnostic.

- **Path validation in every tool.** `read.ts`, `write.ts`, `edit.ts`, `apply_patch.ts` each growing their own `if (!isUnderWorkspace(p))` check is how subtle escape paths leak in. Centralize in `path-policy.ts`; every tool calls it; the rule lives in one place.

- **Symlink resolution at the leaf.** Resolving `realpath(workspace/link/new-file)` to check escape misses the case where `new-file` doesn't exist yet. Resolve at the *deepest existing ancestor* — that catches symlink-parent escapes even when the leaf has not been written.

- **Bind-mounts validated by string-matching the source path.** `if (binds.startsWith("/etc")) reject` falls to `bind: "/var/some-link/with-an-etc-target"` if `some-link` is a symlink to `/etc`. Canonicalize the source through the deepest existing ancestor before allowlist-matching. Reference: same doc section.

- **Foreground and background as separate tools.** A `bash` tool plus a separate `bash_background` tool with its own registry and its own arg parsing is how concurrency models drift apart. One tool with `run_in_background: boolean`, one supervisor, one registry. 

- **Persistent shell session as the primitive.** A long-lived `bash -i` that the model interacts with over many turns is intuitive but fragile: network blips kill it, env-var pollution accumulates, two parallel tool calls race on the same shell. The right primitive is **spawn-per-call with a snapshot file**: capture env once, source it before each command, persist CWD via stdout marker. This is what makes remote backends (SSH, Modal, Daytona) actually work without sticky connection state.

- **Stdout drain via `for line in proc.stdout`.** This blocks on `readline()` until the pipe reaches EOF. When the command backgrounds a grandchild (`cmd & disown`), the grandchild inherits the write end of the stdout pipe; the drain thread never returns; the tool hangs for the lifetime of the grandchild. Use `select()` with a short poll + idle-after-bash-exit threshold instead. This is the kind of bug that only shows up in production; pre-empt it.

- **Process-group leak on abort.** When the local backend spawns subprocesses with `os.setsid` (into their own process group, which is correct) but the abort handler kills only the immediate child, backgrounded grandchildren are reparented to init (`PPID=1`) and survive forever. Kill the whole process group. Use a try/finally pattern around the wait loop.

- **Sandbox escape as a global env-var override.** `SANDBOX_DISABLED=1` or `dangerouslyDisableSandbox: true` per-call without an allowlist of who can request it lets the model ask for elevation directly. Pair escape hatches with a per-surface allowlist (`tools.elevated.allowFrom: { discord: ["user-id"] }`) and a typed *elevation mode*; never expose them as model-controllable flags.

- **Approval logic per tool.** Every tool growing its own `requires_approval` flag and its own approval-message format is how the surface fragments. Centralize at the exec layer; let surfaces (Slack/Discord/Teams) implement their UI, but the classification stays in one place.

- **Browser sandbox sharing the exec sandbox image.** Browsers need Chromium, GPU passthrough, a writable home, a larger disk; exec sandboxes need a minimal Debian. Different containers, different lifecycles, different network policies. Use separate Dockerfiles for exec and browser sandboxes.

- **noVNC access without auth.** Exposing the sandbox browser's noVNC port without a token means anyone on the network can drive the browser. Password-protect with short-lived tokens; put the password in the URL fragment, not the query string or header logs. 

- **Container runtime as the gateway runtime.** Running the harness Gateway *inside* the same Docker container that hosts its sandboxes invites Docker-out-of-Docker (DooD) confusion: paths the harness writes look correct to the Gateway namespace but wrong to the Docker daemon namespace, and you get `EACCES` on heartbeat writes. If you must containerize the Gateway, the workspace path must be the *host's* absolute path *and* the Gateway container must mount the same host path identically. If you must containerize the Gateway, ensure the workspace path is the *host's* absolute path and the Gateway container mounts the same host path identically.

- **`network: "host"` or `network: "container:<id>"` by default.** Both let the sandbox bypass the harness's network policy. Default to `"none"` (Docker's no-network); make namespace-join an explicit break-glass (`dangerouslyAllowContainerNamespaceJoin: true`). 

- **Mounting credential roots by default.** `~/.aws`, `~/.ssh`, `~/.config`, `~/.docker`, `~/.gnupg`, `~/.netrc`, `~/.cargo`, `~/.npm` are credential roots. Block them at the bind-mount allowlist; require explicit opt-in. 

---
