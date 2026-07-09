# Session persistence (SwiftAgentHarness)

On-disk layout: **SQLite catalog** (`catalog.sqlite`) plus **per-conversation JSONL transcripts** under `agents/<agentId>/sessions/`. In-memory tests use ``InMemoryHarnessSessionPersistence`` (no file locks).

Production installs ``LocalHarnessSessionPersistence`` when `SAH_SESSION_STORE_ROOT` is set. All durable conversation mutations flow through ``ConversationPersistenceDomain`` (actor) → ``ConversationPersistenceStack`` → ``ConversationManager`` / ``HarnessSessionPersistence``.

## Single-writer assumption (X4)

**Default deployment: one server process is the only writer to a given session store.**

Persistence is DB-backed (SQLite catalog + JSONL transcript index) and reached only through actor-isolated composition-root paths (`ConversationPersistenceDomain`, `HarnessRuntimeSession`). Within that process:

- Transcript appends are serialized per conversation (transcript write lock + sequence allocation).
- The runtime enforces **one active run per conversation** (per-session lane), so concurrent model turns do not race on the same transcript tail.
- Catalog writes use SQLite WAL with `busy_timeout` and application-level retry — tuned for multiple *tasks* in one process, not multiple *hosts* on one directory.

Under this assumption, the **pid + starttime process-aware lockfile** (`<conversationId>.jsonl.lock`) is **not what provides correctness** for normal server operation. Actor routing and per-conversation lock ordering are. The on-disk lock machinery remains implemented for spec parity and for the multi-process case below.

### Caveat: second process on the same store

The file lock **is required** when more than one OS process can mutate the same `SAH_SESSION_STORE_ROOT`, for example:

- A long-running **server** and a **CLI** (or second harness binary) both pointed at the same session directory
- An external compaction/repair tool writing JSONL while the server is up
- Future multi-host attachment to one shared transcript directory

Without cross-process locking, two writers can interleave JSONL lines or diverge catalog sequence from transcript tail. ``ProcessAwareTranscriptWriteLock`` (advisory `flock`, payload with `pid` + process start token, stale reap, signal cleanup) is the harness answer for that deployment shape.

**Do not point two live writers at the same store unless you accept file-lock contention semantics.** For local development, prefer one process per store root or separate `SAH_SESSION_STORE_ROOT` / `SAH_SESSION_AGENT_ID` per binary.

## Transcript write lock surfaces

| Backend | Lock implementation | Cross-process |
|--------|---------------------|---------------|
| ``InMemoryHarnessSessionPersistence`` | ``InProcessTranscriptWriteLock`` | No (tests only) |
| ``LocalHarnessSessionPersistence`` | ``ProcessAwareTranscriptWriteLock`` | Yes (when second process shares root) |

Configuration (see ``SessionPersistenceConfiguration``):

- `SAH_TRANSCRIPT_LOCK_TIMEOUT_MS` — max wait on acquire (default 30s)
- `SAH_SESSION_ENFORCE_TRANSCRIPT_LOCK=1` — debug guard: append paths require lock held on current thread (Gap 11 / `LockNotHeld`)

## Related

- Harness spec (full Protocol + multi-process rationale): [harness-template/backends/persistence/README.md](../../../../harness-template/backends/persistence/README.md)
- Conversation Manager persistence boundary: [Core/ConversationManager/README.md](../../Core/ConversationManager/README.md)
- Parallel execution / transcript lock in tool batches: [harness-template/core/tool-system/parallel-execution.md](../../../../harness-template/core/tool-system/parallel-execution.md)
