import Foundation

/// Final user turn for `OllamaContextCompactionSummarizer` (after the system instruction and in-order middle messages).
/// `DynamicPrompt` token names: `summary_budget`, `identifier_preservation_block`, `custom_instructions_block`, `memory_provider_pre_compress_block`.
enum ContextCompactionHandoffUserPromptTemplate {
    // swiftformat:disable all
    static let value = #"""
    Summarize the conversation above so it can replace the earlier turns in
    context. The next assistant will see your summary alongside only the most
    recent messages and must continue without re-asking questions or redoing
    work.

    {{previous_summary_block}}

    {{memory_provider_pre_compress_block}}

    # Method

    Open with an <analysis> block as your scratchpad. Walk the conversation
    chronologically: for each turn, what did the user ask, what did the
    assistant do, what was the outcome, and what state did it leave behind.
    Distinguish completed / in-progress / blocked / pending / resolved — most
    summaries fail by conflating these. Capture concrete artifacts: file
    paths, line numbers, function and symbol names, command outputs, exit
    codes, error strings. Watch for user corrections, preferences, and
    quiet confirmations of non-obvious choices; these are easy to lose and
    load-bearing on resume. Mark anything you cannot verify as "unknown"
    rather than guessing.

    Then close the analysis and produce a <summary> block in the exact
    format below. Every section must appear. If a section has no content,
    write "None." — do not omit it.

    # Format

    ## Active Task
    Quote the user's most recent unfulfilled request VERBATIM, in the user's
    own words. If multiple asks were made and only some are done, list only
    the ones still owed. Example:
      User asked: "Now refactor the auth module to use JWT instead of sessions"
    If the last task concluded cleanly, write:
      "None — last task concluded; next assistant should wait for user input."

    ## Overall Goal
    What the user is trying to accomplish across the session, beyond the
    immediate ask. One or two sentences.

    ## Constraints & Preferences
    Stated requirements: language, framework, style, tools they want or
    refuse, deadlines, scope boundaries. Quote where the user was specific.

    ## Active State
    Snapshot of the working environment right now:
    - Working directory
    - Git branch (clean / dirty)
    - Modified files (one-line note each)
    - Created files (one-line note each)
    - Test status (X/Y passing, named failures, last run)
    - Running processes or servers
    - Other relevant environment state

    The next assistant should be able to read this and know where things
    stand without re-running anything.

    ## Completed Actions
    Numbered, oldest to newest. Format:
      N. ACTION target — outcome [tool: name]

    Example:
      1. READ src/auth/session.py:1-145 — found `expires_at` is in seconds not ms [tool: read_file]
      2. PATCH src/auth/session.py:62 — changed `time()` to `time() * 1000` [tool: edit_file]
      3. RUN `pytest tests/auth/` — 23/24 passing; test_token_refresh fails at L47 [tool: bash]

    Be specific. "Made some changes" is not acceptable.

    ## In Progress
    Work underway when summarization triggered: what was being attempted,
    how far it got, what's left on this particular item. "None." if nothing
    is mid-flight.

    ## Blocked
    Issues stopping forward progress: unresolved errors, missing info,
    unavailable resources, decisions waiting on the user. Include exact
    error text and the failing command or operation.

    ## Key Decisions
    Technical or design decisions made this session, with rationale:
    - **Decision**: why
    Example:
    - **JWT with 15-minute expiry instead of long-lived sessions**: user
      requirement for stateless auth across services

    These are decisions the next assistant should not relitigate without
    cause.

    ## Files

    ### Examined
    - path/to/file (read lines N-M) — what was learned

    ### Modified or Created
    - path/to/file — what changed and why
    - path/to/file (new) — what it contains and why

    For files where exact content matters for continuation, inline a brief
    snippet (~30 lines max). For larger files, describe the shape.

    ## Errors & Fixes
    Errors hit AND resolved this session. Errors still unresolved go in
    Blocked, not here. Format:
    - **Error**: exact message or symptom
      - Cause: what was actually wrong
      - Fix: what was changed
      - User feedback: any correction the user expressed (verbatim if specific)

    ## Resolved Questions
    Questions the user asked that have already been answered. Paraphrase
    the question, give the concise answer. The next assistant should not
    re-answer these.

    ## Pending User Asks
    Outstanding requests or questions from the user that have NOT been
    answered or fulfilled, beyond the Active Task.

    ## Critical Context
    Specific values, configuration details, edge cases, or data the next
    assistant will need that don't fit cleanly above. Things lost without
    explicit preservation: exact strings, magic numbers, environment
    quirks, gotchas discovered. NEVER preserve credentials — write
    [REDACTED] instead.

    # Specifics

    - Be CONCRETE. File paths, line numbers, function names, command
      outputs, exit codes, exact values.
    - Preserve the user's exact wording in Active Task and Constraints &
      Preferences. Verbatim quotes prevent task drift across the handoff.
    - Distinguish completed / in-progress / blocked / pending / resolved.
      Conflating these is the most common way summaries mislead.
    - Target roughly {{summary_budget}} tokens for the <summary> body.
      Cut redundancy first; preserve specifics.

    {{identifier_preservation_block}}

    {{custom_instructions_block}}

    REMINDER: <analysis> block followed by <summary> block, plain text
    only. The <analysis> is your scratchpad — only the <summary> will be
    passed to the next assistant.
    """#
    // swiftformat:enable all
}
