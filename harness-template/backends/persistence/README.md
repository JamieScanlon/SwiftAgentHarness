# Persistence

## TL;DR

Persistence is **not one store** — it is a layered backend with three retention classes, sitting behind a single Protocol the inner ring talks to:

1. **Transcript log** — one JSONL file per conversation, entries form a tree via `id` / `parentId` so branches and compactions live in place. Versioned header line. Append-mostly, never rewritten except under a process-aware file lock.
2. **Catalog** — a single SQLite database (WAL mode, FTS5 over message content) holding cross-conversation metadata: lineage, source / trust class, lifecycle state, token / cost rollups, titles, search index. Idempotent ADD-COLUMN migrations.
3. **Adjacent specialized stores** — scheduled-task / cron run history (JSONL per job), inbound idempotency dedupe cache (TTL'd), per-agent auth profiles (file, never auto-shared), Context Engine `engineArtifacts` cache (regenerable from the log), and a **media/blob store** for binary attachments (content-addressed files; durable lane that outlives compaction + ephemeral TTL lane for channel media — the transcript references a `blobId`, never inlines bytes).

This is the recommended design. The alternatives section covers designs that fail under multi-process load, with the constraints under which they could still be defensible.

For the backend's place in the architecture see [`../../core/`](../../core/); for the Conversation Manager that owns conversation CRUD see [`../../core/conversation-manager/`](../../core/conversation-manager/).

---

## What persistence stores

The eight inner-ring layers, the surfaces (triggers / channels), and the auxiliary subsystems (cron, sub-agent runs) all converge on a small set of resources. Pinning down what is persisted *vs.* derivable *vs.* ephemeral is the single most important design call.

| Resource | Class | Owner layer | Form |
|---|---|---|---|
| Conversation header | catalog | Conversation Manager | row in `conversations` |
| Message log (event journal) | transcript | Conversation Manager + Agent Runtime | append-mostly JSONL, tree-structured |
| Compaction summary | transcript | Context Engine | entry inside the same JSONL |
| Branch summary | transcript | Conversation Manager | entry inside the same JSONL |
| `engineArtifacts` (assembled view, system-prompt build, compacted view cache) | regenerable cache | Context Engine | files under `cache/engine-artifacts/<conversationId>/` |
| Sub-agent run | nested transcript | Sub-Agent Pool | nested JSONL, parented in catalog |
| Durable attachment bytes | blob (durable) | Conversation Manager (metadata) | content-addressed file under `media/blobs/` |
| Ephemeral inbound/outbound media | blob (TTL) | Comm Layer + channel surfaces | TTL'd file under `media/inbound/` `media/outbound/` |
| Scheduled task definition | catalog | Triggers / scheduling | row in `tasks` |
| Cron run history (per job) | adjacent JSONL | Triggers / scheduling | `cron/runs/<jobId>.jsonl` |
| Inbound idempotency dedupe | TTL cache | Comm Layer + channel surfaces | `cache/dedupe.sqlite` (or in-memory in embedded mode) |
| Per-agent auth profiles | per-agent file | Conversation Manager (per-agent isolation boundary) | `agents/<agentId>/auth-profiles.json` |
| Subscription seq numbers / replay window | catalog or in-memory | Comm Layer | derived from transcript offsets |
| Token / cost rollups | catalog | Model Pool (writes), Conversation Manager (reads) | columns on `conversations` + `messages` |
| Memory store | **out of scope** | Memory subsystem (inner-ring peer layer) | see [`core/memory/`](../../core/memory/) |

**Memory is deliberately not in this backend's surface.** Memory is one of the eight inner-ring layers — its own peer subsystem with write-side concerns (consolidation, decay, scoring) that warrant a dedicated backend lane. Pluggable memory backends — `memory-core`, `memory-lancedb`, `memory-wiki`, QMD, Honcho — sit on the same Protocol shape conceptually but evolve at their own cadence. Don't bake memory schema into the conversation persistence layer.

**Binary bytes never live inline in the transcript or the catalog.** A user-uploaded image, a generated audio clip, a fetched PDF, a screenshot from a channel — the *metadata* (`id`, `kind`, `name`, `mimeType`, `size`, `trust`, `addedAt`) is owned by the Conversation Manager as an `AttachedResource` (see [conversation-manager § Attached resources](../../core/conversation-manager/#attached-resources)), but the bytes live in a dedicated **media/blob store** keyed by a content hash. The transcript carries a reference (`blobId` / `mediaId`), never the base64. Two reasons this is its own retention class and not a corner of `cache/`: (1) durable attachments must outlive compaction and survive a catalog rebuild, which `cache/` explicitly may not; (2) channel-inbound media is *ephemeral* — it exists only long enough to be delivered into a turn or out to a platform — and wants a short TTL, the opposite lifecycle. **The ephemeral-vs-durable split is the single design call the reference harnesses get wrong by omission**: Most OSS harnesses implement only the ephemeral side (a short-TTL `media/` dir), with no substantive blob handling for the durable case. Specify both lifecycles explicitly.

---

## What depends on it

Mapping to the eight inner-ring layers:

- **Conversation Manager** — primary client. CRUD on conversations, branching, sub-agent nesting (sub-agent = nested conversation, recursing on the same backend).
- **Agent Runtime** — append-only writer during the turn loop. Stateless across calls, so every iteration produces journal entries it persists *via* the Conversation Manager, not directly.
- **Context Engine** — heavy reader of the transcript; writer of `engineArtifacts` (the cache class). Compaction writes a `compaction` entry into the log and may write a derived view into the artifact cache; it never rewrites prior messages. The 2026-04-28 update to the Conversation Manager doc made this distinction load-bearing — preserve it physically by separating `cache/` from `agents/<agentId>/sessions/`. Also a *reader* of the blob store: at `assembleForTurn` it resolves an attachment's `blobId` to bytes (or a summary) per its trust class.
- **Sub-Agent Pool** — persists nested conversations and records cost-per-invocation across the wire. Delegate runs survive parent disconnect because conversations, not connections, are addressable.
- **Communication Layer** — uses the catalog for `list` / `search` / capability queries on the control plane, and reads the transcript with sequence numbers to drive `reconcile-and-watch` + replay window on the data plane. Sequence numbers are file offsets or row ids — pick one and stick to it.
- **Tool System** — tool-result *entries* flow through Agent Runtime, not directly. But tools that produce binary output (screenshot, image-gen, TTS, file-download) are blob-store writers: they `put_blob` the bytes and return a `blobId` in the tool result, keeping the transcript free of base64.
- **Model Pool** — mostly stateless w.r.t. persistence, but token-cost rollups land in the catalog when conversations finalize, and prompt-cache hit metadata is worth recording at the message level (e.g. `cache_read_tokens`, `cache_write_tokens`, `reasoning_tokens` per message).

Surfaces and auxiliary subsystems:

- **Triggers / channel surfaces** — depend on persistence for *session routing* (the `dmScope` resolver picks a conversation id from inbound envelope fields) and the *idempotency dedupe cache*. Neither sits in the inner ring but both block on this backend.
- **Scheduling / cron** — depend on the run-history store for restart catchup ("did this job already deliver after the last crash?").
- **Memory** — peer, not dependent. The transcript can be ingested *into* memory as a separate batch job (the "dreaming" path), but memory must not read the transcript at runtime.

---

## API surface

This is the in-process API the eight inner-ring layers and the surfaces call. The Communication Layer separately exposes a *subset* over the wire (multi-client conversation attach, reconcile-and-watch); see [`../../core/communication-layer/`](../../core/communication-layer/) for that. The two surfaces share the same resource shapes — the catalog rows are what the wire schema serializes — but the in-process API has additional operations the wire never exposes (acquiring transcript write locks, walking artifact caches, raw lineage reads).

The surface is **one Protocol** that distinguishes catalog operations (SQL-shaped, transactional, multi-writer) from transcript operations (append/read/lock-shaped, single-writer-per-conversation). Mixing the two is the most common shape error — Snapshot-oriented backends (`save_snapshot` / `load_latest`) are too coarse for the streaming case; concrete-class DBs with no abstraction, and utility functions with no Protocol, are both harder to test and replace. The shape below is what the inner ring actually needs.

### Resource model

The types callers receive and pass. Schema-defined as TypeBox / Zod / protobuf per the architecture lock-in, so client SDKs can be generated;.

```python
@dataclass(frozen=True)
class Conversation:
    id: str
    agent_id: str
    source: Literal["cli", "channel", "trigger", "acp", "delegate", ...]
    trust_class: Literal["user", "owner", "channel-trusted", "channel-untrusted", "system"]
    parent_id: str | None              # lineage; None for roots
    parent_entry_id: str | None        # which entry in the parent we forked from
    user_id: str | None
    model: str | None
    mode: Literal["chat", "agent"]
    lifecycle_state: Literal["open", "paused", "compacted", "ended"]
    title: str | None                  # UNIQUE among non-NULL titles
    cwd: str | None
    started_at: float
    ended_at: float | None
    end_reason: str | None
    message_count: int
    tool_call_count: int
    tokens: TokenRollup                # input/output/cache_read/cache_write/reasoning
    cost: CostRollup                   # estimated/actual/status/source/pricing_version

@dataclass(frozen=True)
class Entry:
    id: str                            # 8-hex convention
    parent_id: str | None              # parent in the tree (None for the entry that follows the header)
    type: str                          # "message" | "compaction" | "branch_summary" | "model_change" | "thinking_level_change" | "custom"
    sequence: int                      # monotonically increasing per conversation; assigned on append
    timestamp: str                     # ISO8601
    payload: dict                      # type-discriminated body; see entry-types section

@dataclass(frozen=True)
class MessageHit:
    conversation_id: str
    entry_id: str
    sequence: int
    snippet: str                       # FTS5 highlighted excerpt
    score: float
    timestamp: str

@dataclass(frozen=True)
class BlobRef:
    id: str                            # content hash (sha256) of the bytes; the addressable id
    mime_type: str                     # sniffed at store time, not trusted from caller
    size: int
    original_name: str | None          # recoverable display name; not the storage key
    durability: Literal["durable", "ephemeral"]
    trust: Literal["user-direct", "unknown-party", "system"]   # mirrors AttachedResource.trust
    created_at: float
    expires_at: float | None           # set for ephemeral; None for durable

class WriteLock(Protocol):
    conversation_id: str
    acquired_at: float
    def __enter__(self) -> "WriteLock": ...
    def __exit__(self, *exc) -> None: ...
```

`Entry.payload` is type-discriminated and not enumerated here — the entry-type schema lives in `core/conversation-manager/` since that's the layer that owns the resource shape. Persistence treats payloads as opaque JSON.

### Operations, by domain

```python
class SessionBackend(Protocol):
    # ── Conversation lifecycle (catalog) ───────────────────────────────────
    def create_conversation(
        self, *, agent_id: str, source: str, trust_class: str,
        parent_id: str | None = None, parent_entry_id: str | None = None,
        cwd: str | None = None, model: str | None = None, mode: str = "agent",
        title: str | None = None,
    ) -> Conversation: ...

    def get_conversation(self, conversation_id: str) -> Conversation | None: ...

    def list_conversations(
        self, *, agent_id: str | None = None, source: str | None = None,
        cwd: str | None = None, lifecycle_state: str | None = None,
        since: float | None = None, limit: int = 50, cursor: str | None = None,
    ) -> ConversationPage: ...        # cursor-paginated

    def update_conversation(self, conversation_id: str, **fields) -> Conversation: ...
    def set_lifecycle_state(self, conversation_id: str, state: str) -> None: ...
    def end_conversation(self, conversation_id: str, end_reason: str) -> None: ...
    def reopen_conversation(self, conversation_id: str) -> None: ...

    def set_title(self, conversation_id: str, title: str) -> None: ...   # raises TitleConflict
    def resolve_by_title(self, title: str) -> str | None: ...             # exact match; raises TitleAmbiguous on >1
    def resolve_latest_in_lineage(self, base_title: str) -> str | None: ...  # exact or "base #N"; latest by started_at
    def next_title_in_lineage(self, title: str) -> str: ...               # "Foo" → "Foo #2"

    # ── Transcript I/O ─────────────────────────────────────────────────────
    def append_entry(self, conversation_id: str, entry: Entry) -> int: ...
        # returns assigned sequence; durable on return; updates message_count atomically.
        # caller must hold the write lock for this conversation.

    def append_entries(self, conversation_id: str, entries: Iterable[Entry]) -> list[int]: ...
        # batch append in a single fsync; same lock requirement.

    def read_transcript(
        self, conversation_id: str, *, from_seq: int | None = None,
        to_seq: int | None = None, limit: int | None = None,
    ) -> Iterator[Entry]: ...        # snapshot iterator; safe to iterate while writers append.

    def read_lineage(
        self, conversation_id: str, leaf_id: str,
    ) -> Iterator[Entry]: ...        # walks parent_id chain root → leaf for the active branch.

    def get_entry(self, conversation_id: str, entry_id: str) -> Entry | None: ...

    def get_children(
        self, conversation_id: str, parent_entry_id: str,
    ) -> list[Entry]: ...             # for /tree branch picker.

    def acquire_write_lock(
        self, conversation_id: str, *,
        allow_reentrant: bool = False, timeout_ms: int = 30_000,
    ) -> WriteLock: ...               # context manager; raises LockTimeout / LockStale.

    def record_compaction(
        self, conversation_id: str, *, summary: str, first_kept_entry_id: str,
        tokens_before: int, details: dict | None = None,
    ) -> int: ...                     # writes a compaction entry; returns sequence.

    def record_branch_summary(
        self, conversation_id: str, *, from_entry_id: str, summary: str,
        details: dict | None = None,
    ) -> int: ...

    # ── Search ─────────────────────────────────────────────────────────────
    def search_messages(
        self, query: str, *, agent_id: str | None = None,
        conversation_id: str | None = None, limit: int = 25,
    ) -> list[MessageHit]: ...        # FTS5 MATCH; query is sanitized.

    def first_user_prompt(self, conversation_id: str) -> str | None: ...
        # cheap accessor backed by catalog or head-buffer scan.

    # ── Sub-conversations ──────────────────────────────────────────────────
    def fork_conversation(
        self, parent_id: str, *, from_entry_id: str, mode: str | None = None,
    ) -> Conversation: ...            # in-place fork; new conversation inherits agent_id + cwd.

    def list_children(self, parent_id: str) -> list[Conversation]: ...

    # ── Engine-artifact cache (regenerable) ────────────────────────────────
    def get_engine_artifact(self, conversation_id: str, key: str) -> bytes | None: ...
    def put_engine_artifact(self, conversation_id: str, key: str, value: bytes) -> None: ...
    def evict_engine_artifacts(self, conversation_id: str, *, key: str | None = None) -> None: ...

    # ── Media / blob store ─────────────────────────────────────────────────
    def put_blob(
        self, data: bytes | BinaryIO, *, durability: str = "durable",
        original_name: str | None = None, mime_type: str | None = None,
        trust: str = "user-direct", ttl_seconds: int | None = None,
    ) -> BlobRef: ...                 # content-addressed; mime sniffed if not given.
                                       # ttl_seconds required when durability="ephemeral".

    def put_blob_from_url(
        self, url: str, *, durability: str = "ephemeral",
        trust: str = "unknown-party", ttl_seconds: int | None = None,
        max_bytes: int | None = None,
    ) -> BlobRef: ...                 # SSRF-guarded fetch; trust defaults to unknown-party.

    def get_blob(self, blob_id: str) -> BinaryIO | None: ...   # streamed; raises BlobExpired if TTL passed.
    def stat_blob(self, blob_id: str) -> BlobRef | None: ...   # metadata only, no bytes.
    def blob_path(self, blob_id: str) -> Path | None: ...      # for sandbox mounts; see semantics.
    def promote_blob(self, blob_id: str) -> BlobRef: ...       # ephemeral → durable (user attached it for keeps).
    def delete_blob(self, blob_id: str) -> None: ...           # durable delete; ephemeral expires on its own.
    def sweep_expired_blobs(self) -> int: ...                  # background pass; returns count reaped.

    # ── Idempotency / dedupe ───────────────────────────────────────────────
    def dedupe_check_and_set(
        self, idempotency_key: str, *, ttl_seconds: int,
    ) -> bool: ...                    # True = first sighting (caller proceeds).
                                       # False = duplicate (caller drops).

    # ── Sequence / replay (Comm Layer) ─────────────────────────────────────
    def latest_sequence(self, conversation_id: str) -> int: ...
    def subscribe(
        self, conversation_id: str, *, from_seq: int,
    ) -> AsyncIterator[Entry]: ...    # tail follow; replays from from_seq, then live.

    # ── Scheduled tasks / cron run history ─────────────────────────────────
    def upsert_task(self, task: Task) -> None: ...
    def list_tasks(self, *, agent_id: str | None = None) -> list[Task]: ...
    def append_task_run(self, task_id: str, run: TaskRun) -> None: ...
    def tail_task_runs(self, task_id: str, n: int = 100) -> list[TaskRun]: ...
    def latest_undelivered_run(self, task_id: str) -> TaskRun | None: ...

    # ── Per-agent isolation ────────────────────────────────────────────────
    def agent_dir(self, agent_id: str) -> Path: ...                       # creates if missing.
    def auth_profile(self, agent_id: str, name: str) -> AuthProfile | None: ...
    def list_agents(self) -> list[str]: ...
```

Two implementations ship by default:

- `LocalSessionBackend` — the disk layout described under "Layout on disk" below; default for both server and embedded mode.
- `InMemorySessionBackend` — for tests and ephemeral CI; same Protocol, no disk, no FTS, no locks.

A third implementation (`PostgresSessionBackend`) is the migration path for multi-host gateways and is the reason the catalog and transcript surfaces are kept distinct: a Postgres catalog with object-storage-backed transcripts is a viable swap for Local without changing any caller.

### Semantics callers can rely on

**Append durability.** `append_entry` is durable on return: the JSONL line is fsync'd, the catalog `messages` row is committed, `message_count` and token rollups are updated atomically. Callers do not need a separate "commit" step. The returned `sequence` is the canonical addressable id for replay and reconcile-and-watch.

**Lock semantics.** `acquire_write_lock` is a context manager. Re-entrancy is opt-in (`allow_reentrant=True`); the default is non-reentrant so a compaction job that tries to re-enter while a foreground writer holds the lock fails fast at acquire time rather than corrupting the file. The lock is process-aware (see "Concurrency" in Recommendation) — acquire from any process; staleness is detected via `pid` + `starttime`. Callers do not see lock-file paths.

**Read consistency.** `read_transcript` returns a *snapshot iterator* — the entries that existed at iterator creation, in sequence order, even if writers append concurrently. To follow live appends, use `subscribe`. `read_lineage` is similarly snapshot but walks the parent chain.

**Sequence numbers.** Monotonic per conversation, assigned by `append_entry` under the write lock, with no gaps within a conversation. Cross-conversation comparisons are meaningless. The Comm Layer's reconcile-and-watch contract uses `(conversation_id, sequence)` as the cursor; the replay window is bounded by retention policy, not in-memory.

**Idempotency contract.** `dedupe_check_and_set` is single-call check-and-set: True means *this caller* owns the first sighting and must proceed; False means *some other caller* (or this one on a redelivery) already claimed it and the caller must drop. The cache is TTL'd; expiration after a long redelivery window is a deliberate trade-off — the cost of a stale-cache miss is one duplicate run.

**Blob durability and addressing.** `put_blob` is content-addressed: the returned `id` is the sha256 of the bytes, so storing the same bytes twice is idempotent and dedupes for free (a screenshot pasted into two conversations is one file). `durability="durable"` blobs survive compaction, branch, and catalog rebuild and are deleted only by explicit `delete_blob`; `durability="ephemeral"` blobs carry an `expires_at` and are reaped by `sweep_expired_blobs` after their TTL — `get_blob` on an expired id raises `BlobExpired`, it does not silently resurrect. `promote_blob` is the one-way transition for "this inbound media is now a real attachment the user wants kept" — it clears `expires_at` and moves the file from `media/inbound/` to `media/blobs/`. MIME type is sniffed from content at store time and is authoritative; a caller-supplied `mime_type` is a hint only. `blob_path` returns a real filesystem path for the sandbox-mount case (a tool that needs the file on disk inside a container) — files are written mode `0o644` so a non-owner sandbox UID can read them, while the containing `media/` directories stay `0o700` as the trust boundary; everywhere else callers stream via `get_blob` and never see paths.

**Title uniqueness.** `set_title` raises `TitleConflict` if another non-ended conversation holds the title. Comparison is case-sensitive and byte-exact: the partial unique index on `sessions(title) WHERE title IS NOT NULL` uses SQLite's default binary collation, with no `COLLATE NOCASE`. Callers handle conflicts by either picking a different title or calling `next_title_in_lineage(existing)` which auto-suffixes (`"Fix Docker Build"` → `"Fix Docker Build #2"`). `sanitize_title` normalizes whitespace and strips control characters but does not change case; apply Unicode NFC at sanitize time so `"café"` (U+00E9) and `"café"` (U+0065 U+0301) collapse to one canonical form before they reach the index.

**Title resolution.** `resolve_by_title` is an exact lookup, not a fuzzy one. Three outcomes, each with distinct caller handling:

- *Exactly one match* — returns the conversation id.
- *No match* — returns `None`. The caller's pattern is fall-through, typically `resolve_by_title(key) or create_conversation(...)`.
- *More than one match* — raises `TitleAmbiguous(title, candidate_ids)`. This is an invariant violation: the partial unique index makes >1 structurally impossible under normal operation, so when it happens the cause is corrupt data, a skipped migration, or out-of-band SQL. Surfacing it as an error prevents the failure mode where the caller's `or create_conversation(...)` chain silently grows orphaned rows.

Lineage-aware lookup ("prefer the latest `base #N`") is exposed as a separate operation, `resolve_latest_in_lineage`. It uses `started_at` as a total tiebreaker, so its return is always single-id-or-None and never ambiguous. CLIs that want forgiving `/resume <title>` matching should layer a fuzzy picker on top of these two operations rather than pushing fuzziness into the Protocol — the routing-safe exact semantics are load-bearing for the channel-surface use case (the `dmScope`-routed `resolve_by_title(session_key) or create_conversation(...)` pattern below).

**Transactional scope.** Catalog ops are serializable per row; cross-conversation atomic updates are not provided. Transcript appends are atomic per entry (or per `append_entries` batch). There is no cross-store transaction spanning catalog + transcript — the two stores are reconciled by sequence number, not by 2PC. If the catalog row update fails after the transcript append succeeds, the transcript wins on read and a background reconciler patches the catalog from the JSONL header + tail.

**Cancellation.** Long-running iterators (`read_transcript`, `subscribe`) honor caller cancellation. In-flight `append_entry` does not — if the caller cancels mid-fsync, the entry is still durable.

### Per-consumer call patterns

What each inner-ring layer actually calls. Sketches, not exhaustive.

**Conversation Manager** — primary client. Owns the lifecycle. Typical sequences:

```python
# Create from CLI start-up
conv = backend.create_conversation(agent_id=agent.id, source="cli", trust_class="user", cwd=cwd, mode="agent")

# Resume by id
conv = backend.get_conversation(conversation_id)
entries = list(backend.read_lineage(conversation_id, leaf_id=resume_leaf))

# Branch on /fork
child = backend.fork_conversation(parent.id, from_entry_id=branch_point)

# End on /reset or shutdown
backend.end_conversation(conv.id, end_reason="user_exit")
```

**Agent Runtime** — append-only writer during the turn loop. Holds the write lock for the duration of a turn (or briefly per append, depending on how aggressively you batch fsyncs):

```python
with backend.acquire_write_lock(conv.id) as lock:
    backend.append_entry(conv.id, user_message_entry)
    for assistant_chunk in stream:
        ...
    backend.append_entries(conv.id, [assistant_message_entry, *tool_call_entries])
    for tool_result in tool_results:
        backend.append_entry(conv.id, tool_result_entry)
```

**Context Engine** — heavy reader, cache writer:

```python
# Assemble next turn
entries = list(backend.read_lineage(conv.id, leaf_id=conv.head_entry_id))
artifact = backend.get_engine_artifact(conv.id, "assembled-view-v3")
if artifact is None:
    artifact = assemble(entries)
    backend.put_engine_artifact(conv.id, "assembled-view-v3", artifact)

# Compact in place
with backend.acquire_write_lock(conv.id):
    seq = backend.record_compaction(conv.id, summary=..., first_kept_entry_id=..., tokens_before=...)
    backend.evict_engine_artifacts(conv.id)   # next assemble rebuilds.
```

**Sub-Agent Pool** — creates nested conversations, attributes cost:

```python
delegate_conv = backend.create_conversation(
    agent_id=parent.agent_id, source="delegate",
    parent_id=parent.id, parent_entry_id=spawning_entry_id,
    trust_class=parent.trust_class,
)
# ... runtime drives delegate_conv as any other conversation ...
backend.update_conversation(delegate_conv.id, cost=accumulated_cost)
```

**Communication Layer** — control plane reads via `list_conversations` / `search_messages`; data plane uses `subscribe`:

```python
# Control plane: GET /conversations
page = backend.list_conversations(agent_id=request.agent_id, limit=50, cursor=request.cursor)

# Data plane: WebSocket attach
async for entry in backend.subscribe(conv.id, from_seq=client_last_seen):
    yield serialize(entry)
```

**Triggers / channel surfaces** — dedupe inbound, route to a session, then hand off to the runtime:

```python
if not backend.dedupe_check_and_set(envelope.idempotency_key, ttl_seconds=300):
    return  # duplicate redelivery, drop.

session_key = resolve_dm_scope(envelope, channel.dm_scope)
conv_id = backend.resolve_by_title(session_key) or backend.create_conversation(
    agent_id=channel.agent_id, source="channel", trust_class=channel.trust_class,
    title=session_key, cwd=None, mode="agent",
).id
runtime.enqueue(conv_id, envelope)

# Inbound media on the same envelope: store ephemeral, reference by id, let the
# Context Engine pull bytes at assemble time. Promote only if the user keeps it.
for upload in envelope.attachments:
    ref = backend.put_blob(upload.bytes, durability="ephemeral",
                           original_name=upload.name, trust="unknown-party",
                           ttl_seconds=300)
    manager.attach_resource(conv_id, kind="media", blob_id=ref.id,
                            mime_type=ref.mime_type, size=ref.size, trust=ref.trust)
```

**Cron / scheduling** — restart catchup:

```python
for task in backend.list_tasks(agent_id=agent.id):
    last = backend.latest_undelivered_run(task.id)
    if last and is_in_current_window(last, task.schedule):
        deliver(task, last)             # complete the missed delivery.
```

**Conversation Manager** — startup orphan scan. The Manager's restart contract walks the catalog for conversations whose `runStatus` is non-terminal and reconciles them per [conversation-manager/runs.md § Resumption after restart](../../core/conversation-manager/runs.md#resumption-after-restart). Persistence's role is to make this scan cheap (the catalog query is `WHERE run_status IN ('running','awaiting-approval','cancelling')`) and to provide the append path for the `run_orphaned` marker the Manager writes. The scan happens once on Manager startup; sub-agent orphans are picked up by the same scan because nested conversations are stored identically. Reference: [sub-agent-pool § Orphan recovery after gateway restart](../../core/sub-agent-pool/#orphan-recovery-after-gateway-restart).

```python
# Manager startup
for conv in backend.list_conversations(lifecycle_state="open"):
    if conv.run_status in ("running", "awaiting-approval", "cancelling"):
        with backend.acquire_write_lock(conv.id):
            backend.append_entry(conv.id, run_orphaned_entry(conv.current_run_id))
        backend.update_conversation(conv.id, run_status="idle", current_run_id=None)
```

**Memory ingestion (read-only consumer)** — Memory is a peer subsystem, not a dependent. The "dreaming" path uses the read-side API only:

```python
for conv in backend.list_conversations(agent_id=agent.id, since=last_dream_at):
    for entry in backend.read_transcript(conv.id):
        memory.ingest(entry, provenance=(conv.id, entry.sequence))
```

Memory writes its own backend; it does not use any persistence write surface except `dedupe_check_and_set` for ingestion idempotency.

### Errors

A small, typed error set. Callers should not need to inspect strings.

- `ConversationNotFound(conversation_id)`
- `EntryNotFound(conversation_id, entry_id)`
- `LockTimeout(conversation_id, waited_ms)` — `acquire_write_lock` exceeded `timeout_ms`.
- `LockStale(conversation_id, holder_pid)` — recoverable; surface a hint that watchdog will reap.
- `LockNotHeld(conversation_id)` — caller invoked an append/compaction without holding the lock.
- `TitleConflict(title, existing_conversation_id)` — `set_title` collided with the partial unique index.
- `TitleAmbiguous(title, candidate_ids)` — `resolve_by_title` matched >1 row. Indicates a violated unique-index invariant (corrupt data, skipped migration, or out-of-band SQL); surface, do not paper over.
- `IdempotencyHit(idempotency_key)` — only thrown by callers that prefer raise-over-return.
- `SchemaMigrationRequired(catalog_version, transcript_version)` — backend refuses to start until migrations run; the binary surfaces the specific migration.
- `RetentionExceeded(conversation_id, requested_seq, oldest_available_seq)` — `subscribe`/`read_transcript` from a sequence beyond the replay window.
- `BlobNotFound(blob_id)` — `get_blob` / `stat_blob` on an unknown id.
- `BlobExpired(blob_id, expired_at)` — ephemeral blob's TTL passed; distinct from `BlobNotFound` so callers can distinguish "never existed" from "garbage-collected."
- `BlobTooLarge(size, max_bytes)` — `put_blob` / `put_blob_from_url` exceeded the configured cap.

`SQLite OperationalError` and `OSError` are *not* part of the public surface — the LocalSessionBackend translates them into the typed errors above (or retries internally for the well-known transient cases — WAL contention, EAGAIN on locks).

### What is deliberately not exposed

To keep the Protocol stable across implementations, callers do not see:

- Raw SQLite handles, connection pools, or WAL state.
- Lock-file paths, PID payloads, or staleness reaper internals.
- JSONL line offsets or filesystem paths for transcript files. (`agent_dir` is exposed only for auth-profile reads, not for transcript I/O.)
- Schema version numbers (other than via `SchemaMigrationRequired`).
- The dedupe cache's eviction policy or backing store.
- Catalog-vs-transcript reconciliation jobs and their state.
- The media directory layout, hash fan-out, or TTL sweep schedule. (`blob_path` is the one deliberate exception — it returns a real path for the sandbox-mount case; everywhere else callers stream via `get_blob`.)

A caller that reaches around the Protocol to read a JSONL directly is doing the wrong thing — the canonical path is `read_transcript` / `read_lineage`, even in tests.

---

## Recommendation

### Layout on disk

```
<configHome>/
  catalog.sqlite                          # WAL, conversations + messages + FTS5
  catalog.sqlite-wal
  catalog.sqlite-shm
  agents/<agentId>/
    auth-profiles.json
    sessions/
      sessions.json                       # local index, redundant with catalog (recovery)
      <conversationId>.jsonl              # the transcript tree
      <conversationId>.jsonl.lock         # process-aware file lock
  cron/
    runs/<jobId>.jsonl
  media/
    blobs/<hashPrefix>/<blobId>           # durable; content-addressed; survives catalog rebuild
    inbound/<blobId>                      # ephemeral; TTL'd; channel uploads, screenshots
    outbound/<blobId>                     # ephemeral; TTL'd; staged for platform delivery
  cache/
    engine-artifacts/<conversationId>/    # regenerable; safe to evict
    dedupe.sqlite                         # TTL'd; can be in-memory in embedded mode
```

Four reasons the layout is shaped this way:

1. **Per-agent directory isolation.** Reusing `agentDir` across agents collides on auth profiles and session indexes. Make this *physical*, not conventional.
2. **Local `sessions.json` index is redundant with the catalog *on purpose*.** It is the recovery plan for a corrupt or lost catalog: every conversation's existence and lineage can be re-derived from the per-agent directory tree without reading transcript bodies.
3. **`cache/` is one directory tree away from `agents/`** so cache eviction (or full deletion) cannot accidentally damage source-of-truth data.
4. **`media/` is a sibling of `cache/`, not a child of it.** `media/blobs/` holds source-of-truth durable attachments — wiping `cache/` must never touch them. `media/inbound/` and `media/outbound/` are the ephemeral lanes (safe to sweep), kept in separate subdirectories so the TTL reaper can target them without walking the durable tree. The `<hashPrefix>` fan-out (first 2 hex of the blob id) keeps any single directory from accumulating tens of thousands of entries. Media is *per-install*, not per-agent, because content addressing dedupes identical bytes across agents; cross-agent read is gated by the metadata's `trust` field and the attachment ACL the Conversation Manager owns, not by directory walls.

### The transcript log (per conversation)

**One JSONL file per conversation.** Append-mostly. Each line is a JSON object with a `type` field.

**Header line is metadata-only, not part of the tree.** Carries an explicit `version` so loaders can branch:

```json
{"type":"session","version":3,"id":"…","timestamp":"…","cwd":"/path","parentSession":"/path/to/original/session.jsonl"}
```

Mature implementations of this format are on their third header version, with auto-migration v1 → v2 → v3 on load. Same convention here: bump the header version when entry-shape changes; migrate idempotently on first read.

**Tree structure via `id` + `parentId` on every entry.** This is the single highest-leverage choice in the whole design. It lets you:

- Branch in place (no new file per `/fork` or `/clone`)
- Compact in place (a `compaction` entry replaces what the model sees on the *next* turn without rewriting prior entries)
- Resume from a pre-compaction node by picking a different leaf
- Walk lineage cheaply (`current = current.parentId ? byId.get(current.parentId) : undefined`)

Treating the log as linear forces awkward "lineage" tables (e.g. a `parent_session_id` chain) that re-introduce the tree at coarser grain. Don't repeat that.

**Open-set entry types.** The base set:

```
session            (header, line 1 only)
message            (user / assistant / toolResult / thinking)
model_change       (mid-conversation provider/model swap)
thinking_level_change
compaction         (summary + firstKeptEntryId + tokensBefore)
branch_summary     (summary + fromId — abandoned-branch context)
custom             (extension-specific; carries customType discriminator)
```

`custom` is the extension hook — let plugins emit their own typed entries (with a `customType` discriminator) without forking the persistence layer.

**Compaction is replace-in-prompt, not replace-in-log.** A compaction entry carries a summary and `firstKeptEntryId`; the Context Engine assembles the next turn from `[compactionSummary] + entries-from-firstKeptEntryId`. The pre-compact log is preserved on disk so `/resume` from before the compaction works without reaching into a separate archive. This is what makes [compaction](../../core/context-engine/compaction.md) resumable.

### The catalog (single SQLite database, WAL mode)

One `catalog.sqlite` per harness install (or per-agent if your isolation model demands it — see "Tenant isolation" below).

**Tables:**

- `conversations` — id (PK), parent_session_id (FK self), source (cli / channel / trigger / acp / etc.), trust_class, user_id, agent_id, model, model_config (JSON), system_prompt_hash, started_at, ended_at, end_reason, message_count, tool_call_count, input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, reasoning_tokens, billing_provider, estimated_cost_usd, actual_cost_usd, title (UNIQUE NULLS-allowed), cwd, mode (chat / agent), lifecycle_state (open / paused / compacted / ended).
- `messages` — id, conversation_id, role, content, tool_call_id, tool_calls (JSON), tool_name, timestamp, token_count, finish_reason, reasoning, reasoning_details, sequence (monotonically increasing per conversation, used by Comm Layer replay). Index on `(conversation_id, sequence)`.
- `messages_fts` — FTS5 virtual table over `messages.content`, kept in sync via INSERT / UPDATE / DELETE triggers.
- `tasks` — scheduled task registry.
- `schema_version` — single-row integer.
- `state_meta` — single-row key/value table for installation-wide flags.

**WAL mode + foreign keys on:**

```sql
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
```

WAL allows concurrent readers + one writer — the right shape for a Gateway server with many subscribers reading live conversations while the Agent Runtime appends.

**FTS5 over message content.** Cross-session search is required for `/resume`, for the channel-routed "find my conversation about X" pattern, and for memory-system ingestion. This pattern uses an FTS5 virtual table with `content=messages` and `content_rowid=id`, kept in sync by three triggers on `messages` (INSERT / UPDATE / DELETE). Sanitize user queries — FTS5's MATCH syntax has reserved characters that crash the parser if quoted naively.

**Schema versioning baked in from day one.** Idempotent `ALTER TABLE ADD COLUMN` migrations wrapped in try/except. This pattern is at v8; start at v1 and accept that you will reach v8 too. Migration writes are a single transaction and bump `schema_version` only on success.

### Concurrency: write contention is the failure mode

Two stores, two patterns. **Pick the right one for each.**

**Catalog (SQLite, WAL mode):** multiple writers. Use `BEGIN IMMEDIATE` + jittered retry + periodic checkpoint.

```python
_WRITE_MAX_RETRIES = 15
_WRITE_RETRY_MIN_S = 0.020   # 20ms
_WRITE_RETRY_MAX_S = 0.150   # 150ms
_CHECKPOINT_EVERY_N_WRITES = 50
```

`BEGIN IMMEDIATE` acquires the WAL write lock at transaction start, which surfaces contention immediately rather than at COMMIT. The short SQLite timeout (1s, *not* the 30s default) plus application-level retry with random jitter avoids the convoy effect — SQLite's deterministic internal backoff causes all competing writers to retry on the same intervals. Periodic `PRAGMA wal_checkpoint(PASSIVE)` every 50 successful writes flushes WAL frames back into the main DB without blocking any writer.

**Transcript JSONL (per-file):** at most one writer at a time, but writers can come from *any process* (server, CLI client, scheduler, sub-agent runner, compaction job). Use a process-aware file lock.

The lock is:

- **Process-aware** — payload includes `pid` and `starttime` (Linux clock ticks from `/proc/<pid>/stat` field 22). On acquire, check `isPidAlive(pid)` and verify start-time matches; if the holder process is gone or has been reused (PID recycled), the lock is stale and can be reaped. Without start-time, PID recycling masks dead holders.
- **File-based** — survives across the in-process queue. A second process opening the same JSONL must contend for the same lock.
- **Non-reentrant by default** — `allowReentrant: true` is opt-in. This catches the "compaction thread tries to re-enter while the foreground writer still holds the lock" bug at acquire time rather than at half-written-file time.
- **Reaped on signal** — `SIGINT` / `SIGTERM` / `SIGQUIT` / `SIGABRT` handlers release all held locks synchronously before letting the default handler run.
- **Watchdog'd** — periodic check (default 60s) for stale locks held longer than `DEFAULT_MAX_HOLD_MS` (5 min), with grace period before forced release.

**Every transcript write path takes the lock.** Append, compaction-rewrite, repair, branch-summary insertion. Plain in-process mutex isn't enough the moment two clients attach to the same conversation — and the Communication Layer commits us to that case (multiple clients can attach to the same conversation; client disconnect doesn't kill the conversation).

### How the implementation satisfies the Protocol

The full Protocol is documented in [§API surface](#api-surface). What follows are the implementation choices that make the contract above hold:

- **Catalog ops** (`create_conversation`, `list_conversations`, `search_messages`, etc.) → SQLite WAL with `BEGIN IMMEDIATE` + jittered retry. Multi-writer correct.
- **`append_entry` durability** → write JSONL line under the file lock, fsync, then commit the catalog row in the same logical operation. Order matters: JSONL first so the source-of-truth is durable before the index sees it.
- **`acquire_write_lock`** → process-aware file lock at `agents/<agentId>/sessions/<conversationId>.jsonl.lock` with `pid` + `starttime` payload. Watchdog reaps stale holders.
- **`read_transcript` snapshot semantics** → open the JSONL at iterator creation, scan to `from_seq`, stream from there; new appends after iterator open are not seen (use `subscribe` for live tail).
- **`subscribe` tail follow** → `read_transcript(from_seq=)` to drain history, then a file-watch (or in-process broker) for new entries appended after the drain point. Caller never sees the boundary.
- **Engine-artifact cache** → opaque files under `cache/engine-artifacts/<conversationId>/{key}`. No catalog row. Eviction is `rm`.
- **`dedupe_check_and_set`** → separate `cache/dedupe.sqlite` with TTL-driven cleanup (or in-memory map for embedded mode). Not the catalog — different lock contention profile.
- **Typed errors** → `LocalSessionBackend` translates `sqlite3.OperationalError`, `OSError`, `EAGAIN`, etc. into the typed set; transient errors are retried internally.

The Protocol shape covers the catalog and transcript surfaces this design needs.

### Tool / runtime metadata persistence: whitelist, never snapshot

Runtime objects evolve faster than on-disk schema. Don't serialize them directly.

```python
_PERSISTED_TOOL_METADATA_KEYS = (
    "permission_mode",
    "read_file_state",
    "invoked_skills",
    "async_agent_state",
    "async_agent_tasks",
    "recent_work_log",
    "recent_verified_work",
    "task_focus_state",
    "compact_checkpoints",
    "compact_last",
)
```

Anything not in the whitelist isn't persisted. Adding a key requires a deliberate migration (and probably a schema version bump). This is the right discipline because:

1. The runtime is free to add scratch fields without breaking persisted data.
2. The on-disk shape stays auditable — you can grep the whitelist to enumerate everything that survives a restart.
3. Sensitive runtime context (open file handles, in-flight permission tokens) can't accidentally leak to disk by being part of a "context dict."

The same result can be achieved by parsing select fields out of the JSONL with `extractJsonStringField` plus an `extractLastJsonStringField` for fields appended late (custom titles, tags) — same idea, different mechanism.

### Schema versioning, on both sides

Both stores need it. They evolve at different rates.

**Transcript JSONL:** version field on the header line. Auto-migration on first read; rewrite the file under the write lock. This pattern does this on every load.

**Catalog SQLite:** `schema_version` table, idempotent `ALTER TABLE ADD COLUMN` migrations. Each migration is one transaction; version bumps last..

**Why both:** the transcript schema changes when entry types change (rare). The catalog schema changes when query patterns change (often — billing columns, cost columns, reasoning columns added in v5/v6/v7). Same backend, different cadence. One unified version number couples the two and makes both migrations harder than they need to be.

### Lite reads and resume UX

The Communication Layer's `list` endpoint and the CLI's `/resume` picker need conversation summaries fast — without reading the full JSONL. 

Two patterns:

1. **Catalog-first.** All summary fields the picker needs (title, message_count, started_at, model, first user prompt) live in the catalog and are populated on conversation creation + finalization. This is the dominant case — `O(1)` query, no file I/O.
2. **Head/tail buffer fallback.** When the catalog is missing data (recovery, foreign agent dir, cross-project scan), open the JSONL and read a fixed-size head buffer + tail buffer (64KB each), then run a no-allocation field extractor (`extractJsonStringField`) to pull `cwd`, first user prompt, and the last `customTitle` / `tag` without parsing the whole file. Works on truncated lines.

The fallback exists because the catalog is recoverable from on-disk transcripts (the `sessions.json` index + per-file head reads) but not vice versa. The transcript is source of truth; the catalog is a fast index.

### Tenant isolation and `dmScope`

Two distinct isolation boundaries, both load-bearing.

**Per-agent isolation:** every agent gets `agents/<agentId>/` with its own auth profiles and session directory. Auth profiles are *never* auto-shared. Cross-agent transcript access is opt-in via memory-search `extraCollections` (named, per-collection, not implicit).

**Per-channel-peer isolation (`dmScope`):** when channel-routed inbound messages arrive, which conversation do they land in? Four scopes:

- `main` — all DMs share one session. **Information-leak risk on multi-user channels** (Alice's DMs visible to Bob if both DM the same agent). this approach flags this explicitly.
- `per-peer` — isolate by sender.
- `per-channel-peer` — isolate by channel + sender. **Recommended default for any multi-user setup.**
- `per-account-channel-peer` — isolate by account + channel + sender (multi-tenant gateway).

`session.identityLinks` stitches the same person across channels into one session when desired.

The default must not be `main`. Make `per-channel-peer` the default and require an explicit opt-in for `main`. Surface mis-configured `dmScope` as a warning at startup.

### Inbound idempotency dedupe

Side-effecting Comm Layer methods (`send`, `agent`, channel inbound dispatch) require an idempotency key with a short-lived dedupe cache. Channels redeliver after reconnects; without dedupe the agent runs twice on the same message.

**Key shape:** `(channel, account, peer, session_id, message_id)`. **TTL:** minutes, not hours — the cost of a stale-cache miss is one duplicate run; the cost of a never-evicted cache is unbounded growth.

**Storage:** a separate `cache/dedupe.sqlite` with TTL-driven cleanup, *not* the catalog. Different retention class, different lock contention profile. In embedded mode an in-memory map with disk overflow is fine.

### Engine artifacts cache

The Context Engine writes a derived view of the conversation on each compaction or significant ingestion event. Carry an explicit `engineArtifacts` field on entries for "Extension-specific data (e.g., ArtifactIndex, version markers for structured compaction)".

Persistence-side implications:

- Cache files live under `cache/engine-artifacts/<conversationId>/`, keyed by an artifact id the Context Engine controls.
- Eviction is allowed at any time. Cold start reconstructs from the transcript.
- Persistence does not validate artifact contents — opaque blobs to this layer.
- The artifact cache is **not the source of truth.** If the JSONL says one thing and the artifact says another, the JSONL wins. Make this an invariant your loaders enforce.

### Media / blob store

Binary attachments — user uploads, generated images and audio, fetched documents, channel media, screenshots — are stored as files keyed by a content hash, with the conversation referencing the `blobId`. This is the area the reference harnesses leave most incomplete, so the recommendation here is synthesized from the one substantial implementation observed plus a common outbound-delivery convention, with the durable side filled in.

**Content addressing, not per-conversation filenames.** The blob id is the sha256 of the bytes. The same image attached to two conversations, or the same screenshot pasted twice, is one file on disk. This makes `put_blob` idempotent and turns delete into reference-counting (don't unlink until the last referencing conversation drops it). An alternative convention names files `{sanitized-original}---{uuid}.{ext}` and recovers the display name with a regex; that gives uniqueness and a recoverable name but no dedupe. Keep the *recoverable original name* idea — carry it as `original_name` metadata — but make the **storage key** the content hash so identical bytes collapse.

**Two lifecycles, two directories — the design call to get right.**

- **Ephemeral** (`media/inbound/`, `media/outbound/`): channel uploads, screenshots, TTS clips staged for delivery. Short TTL — 2 minutes is a reasonable default; treat media as transient delivery, not storage. A background `cleanOldMedia` pass prunes files older than the TTL and removes empty dirs. This is correct for media that only has to survive long enough to enter one turn or leave on one platform send.
- **Durable** (`media/blobs/`): files the user explicitly attached to a conversation for its lifetime. No TTL; deleted only on explicit `delete_blob` (or when the last referencing conversation is hard-deleted). `promote_blob` is the inbound→durable transition: a screenshot arrives ephemeral, the user says "keep this," it moves to `blobs/` and loses its `expires_at`.

The durable lane is the gap most implementations omit — without it, "attach this PDF to the conversation" either inlines bytes into the transcript (bloats the JSONL, breaks the append-mostly model) or relies on media surviving a short TTL window (it will not). Specify both.

**Permissions are a trust boundary.** Blob files are written mode `0o644` so a non-owner UID inside a sandbox container can read media mounted into it; the containing `media/` directories stay `0o700`. The file mode is deliberately permissive *because* the directory mode is the actual fence. Replicate both halves; loosening the directory mode to match the file mode defeats it.

**Fetched media is SSRF-guarded and trust-tagged.** `put_blob_from_url` must resolve and pin the hostname against an SSRF allowlist before fetching , enforce a byte cap (5 MB is a reasonable default), and tag the result `trust="unknown-party"` — the same trust enum the Conversation Manager puts on agent-fetched attachments. User uploads are `user-direct`. The Context Engine reads this to decide whether to envelope-wrap the content before it reaches the model; losing the tag at the storage boundary loses it everywhere downstream.

**Outbound delivery: a `MEDIA:<path>` tag convention, stripped before display.** this approach lets the model emit `MEDIA:/path/to/file.png` tags in its response; the platform adapter scans the final response and tool results for `MEDIA:(\S+)` matches, delivers each as a native platform attachment (image / voice / video / document by extension), and strips the tags from the visible text. This is a clean way to let a text-only model surface emit binary output without a structured tool-return channel. The persistence-side implication: outbound blobs the model references by tag get staged in `media/outbound/` with a short TTL — they exist to be delivered once, then swept. (Not everything binary-shaped needs the blob store; a description-of-a-blob is catalog data.)

**The blob store is not the source of truth for *whether* an attachment exists — the conversation metadata is.** The Conversation Manager owns the `AttachedResource` list (id, kind, mimeType, size, trust, addedAt) and the reference to the blob; the blob store owns the bytes. A durable blob with no referencing conversation is garbage (sweep it); a conversation referencing a missing durable blob is corruption (surface it, don't paper over with a silent empty read). This mirrors the catalog/transcript split: metadata in one place, the heavy payload in another, reconciled by id.

### Cron run history

Long-running scheduled jobs need restart catchup: "did this delivery already happen before the last crash?" Test coverage for this should cover: persists-delivered-status, restart-catchup, and one-shot-job-disables-itself scenarios.

**Storage:** `cron/runs/<jobId>.jsonl` — one append per run, fields: `run_id`, `job_id`, `started_at`, `ended_at`, `outcome`, `delivered_at` (when applicable), `error`. JSONL because runs are append-only, cheaply-rotateable, and survive a corrupt catalog.

**Restart contract:** on Gateway start, read each cron job's tail (last N lines, default 100) and reconcile against the scheduled trigger. Re-deliver only if the last run for the current trigger window has no `delivered_at`.

---

## Alternatives

### All-SQLite transcript store

Puts everything in one database — sessions, messages, FTS5 index, model config, billing. One database, well-engineered (WAL + jittered retry + checkpoints), and conceptually clean.

**Where it fails:** under multi-process load. The convoy effect is the precise failure — multiple writers (gateway + CLI sessions + worktree agents) all retry on SQLite's deterministic internal backoff and stampede. The mitigations work but the fact that 1s timeouts, 15-retry app-level loops, and 50-write checkpoints are *required* for correctness is itself the warning sign. Append-mostly transcripts and random-access metadata have different access patterns; jamming them into the same store forces both to share contention overhead.

**When it's right:** single-process, single-writer harnesses (a CLI without gateway / triggers / sub-agent runners). Or where you genuinely cannot afford two stores.

### All-JSONL (single-binary CLI alternative)

This approach keeps transcripts at `~/.harness/projects/<sanitized-cwd>/<sessionId>.jsonl` and uses a parallel `history.jsonl` for input history. No central catalog. Resume lists are built by scanning project directories and lite-reading file heads.

**Where it fails:** cross-session search. Without FTS5, an agent that wants to find "the conversation where we discussed the auth migration" has to re-parse JSONL files. This works for a single-user CLI; it does not scale to a Gateway answering channel inbounds.

**When it's right:** local-first, single-user CLIs without channel surfaces. Cheaply portable (just rsync the projects directory).

### Framework checkpointer

Uses a runtime framework's built-in checkpointer (a SQLite-backed saver) with a `thread_id` as the unit of addressability. The framework handles checkpoint serialization and restart.

**Where it fails:** persistence is coupled to framework internals. Monkey-patching internal framework components to satisfy compat requirements becomes inevitable. You inherit the framework's bugs and its release cadence. Swapping runtimes means migrating the schema by hand.

**When it's right:** if your Agent Runtime *is* that framework and you're never going to swap it. Very few harnesses are in that position long-term.

### Per-branch new file (naive)

The intuitive design: every `/fork` writes a new JSONL file with a `parentSession` pointer in its header. Both cross-file forks (via a `parentSession` header field) and in-file branching (via `id`/`parentId`) are supported; in-file branching is the dominant pattern.

**Where it fails:** file count explodes for any non-trivial branch-heavy workflow. Every cross-file pointer is a fragility (rename / move and you've broken lineage). Lineage queries become "open every file in the directory."

**When it's right:** as a *complement* to in-file branching for the explicit-fork case (the user opens a branch they want to share / publish). Not as the primary branch mechanism.

---

## Anti-patterns

- **One SQLite for everything** — see all-SQLite section above. Operationally painful under multi-process load. The convoy mitigations are forced moves, not features.
- **New file per branch** — file count explodes; lineage queries break; cross-file pointers are fragile.
- **Direct serialization of runtime objects** (no whitelist) — schema breaks on every refactor; sensitive runtime context leaks to disk.
- **In-process-only locking on the transcript** — misses the cross-process case (server + CLI + scheduler + sub-agent runner). The architecture lock-in commits us to multi-client conversation attach; this anti-pattern is a guaranteed corruption bug.
- **Default `dmScope` = `main` on multi-user channels** — cross-tenant DM leak. this approach security audit catches it; better not to ship the footgun in the first place.
- **Persistence coupled to a runtime framework's checkpointer** — you inherit their bugs and their cadence; you can't swap runtimes.
- **One table for transcripts, idempotency dedupe, and conversation metadata** — three retention classes (long-lived, short-TTL, queryable), three lock contention profiles, one bottleneck. Separate them.
- **Engine-artifact cache as source of truth** — if a derived view disagrees with the JSONL, the JSONL wins. Make the loader enforce this; make the directory layout reflect it (`cache/` separate from `agents/`).
- **Plain PID file lock without process start-time** — PID recycling masks dead holders; reused PIDs look alive forever. The lock-payload `starttime` field is what makes the staleness check correct.
- **Memory schema baked into conversation persistence** — couples two subsystems that evolve at different rates. Memory has its own backends (`memory-core`, `memory-lancedb`, `memory-wiki`, QMD, Honcho). Keep the surfaces separate.
- **Base64 bytes inlined in the transcript or catalog** — bloats the JSONL (which is read in full on every lineage walk and assemble), bloats every catalog row scan, and breaks the append-mostly model. Store bytes in the blob store; the transcript carries a `blobId`.
- **One TTL for all media** — durable user attachments and 2-minute channel uploads share neither lifecycle nor directory. A single TTL either deletes attachments the user wanted kept or never reaps transient inbound media. Two lanes, two policies.
- **Per-conversation media filenames with no content addressing** — identical bytes attached to N conversations become N files, and delete becomes a guessing game about who else references them. Content-address (sha256) so dedupe and reference-counting fall out for free; keep the original name as metadata, not as the key.
- **Permissive directory mode on the media dir** — files should be `0o644` for sandbox readability *because* the directory stays `0o700`. Loosening the directory to match the file removes the actual fence and exposes media to any local UID.
- **Fetching agent-referenced URLs into the blob store without SSRF guard or trust tag** — an unguarded `put_blob_from_url` is a server-side request forgery primitive; an untagged fetch loses the `unknown-party` trust class the Context Engine needs to decide on envelope-wrapping. Pin the host, cap the bytes, tag the trust.

---
