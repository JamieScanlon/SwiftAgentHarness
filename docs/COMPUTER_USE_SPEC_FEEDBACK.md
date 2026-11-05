# Computer use: open feedback for the spec team

These are the spec issues still open after the November 2026 revisions. Each one is a place where `harness-template/backends/computer-use/README.md`, `macos.md`, or a page they lean on is silent or ambiguous, and the implementation had to choose. Each item gives the problem, what the implementation does, and a suggested change. Spec references are relative to `harness-template/`.

Features the implementation hasn't built yet are tracked in [COMPUTER_USE.md](COMPUTER_USE.md) under "Not built". They aren't spec issues.

## Gaps

### Where `keepFiles` goes

§ Sessions, leases, grants, and tiers ("Managed-browser events") keeps the downloads "the specialist named in its final submission (a `keepFiles` argument …)". The specialist has no submit action: § Verification, ask-user, and handoff are actions lists `verify`, `ask_user`, and `handoff`, and the specialist finishes with its report.

**Implementation:** a `computer_keep_downloads` tool takes the list, one file name or folder path per line. Its latest call is the one that counts.

**Suggest:** name the action that carries `keepFiles`, either a keep action like this one or a submit action the specialist must end with.

### What a returning holder hears about a lease that ended while it was away

`macos.md` § The host protocol has the host act on a detached lease's events itself ("a stop press runs cleanup locally") and send a snapshot on reattach. Once cleanup has run, there is no lease left to snapshot, and the spec doesn't say what the reattach returns.

**Implementation:** the host remembers a lease it ended while detached for the grace period. A reattach presenting that lease's token is told why it ended, once, and the client turns a stop into the stop the session missed. A wrong token is still refused like an unknown lease.

**Suggest:** say whether a reattach after local cleanup reports the ending to the token holder, or is refused like any other.

### Whose windows `describe()` lists on a shared desktop

§ The canonical action model now checks window conditions against `describe()`'s window list. On the host desktop that list could name every app the user has open, which observations otherwise never show.

**Implementation:** the macOS host lists normal windows of granted apps only. A window condition on an app outside the grant is refused.

**Suggest:** say that a target's window list covers granted apps only, as observations do.

### Page content whose address is unknown

§ Sessions, leases, grants, and tiers ("Which part an action hits") puts anything under the web area on the page, where domain grants decide. A web area that doesn't expose its URL leaves no domain to check.

**Implementation:** such an element is unresolvable, so the action is refused and the model is asked to observe again. It doesn't fall back to the browser's app grant.

**Suggest:** state that page content with no known address is refused, not treated as chrome.

## Ambiguous

### What "denying the delegate tool" covers down the chain

§ Permission classification per action gives a mode two levers, and `core/conversation-manager/modes.md` says policy restrictions accumulate while capability is assigned fresh to each child. A tool allow-list that leaves the delegate out is capability; a `deny` entry is a restriction. The spec doesn't say which one an ancestor's mode uses to deny computer use.

**Implementation:** only a tool `deny` that names `delegate_computer_use` reaches delegates below. An ancestor's allow-list doesn't.

**Suggest:** say that denying computer use down the chain takes a `deny` entry.

### A denial that arrives mid-session

§ Permission classification per action applies a tightening "from the session's next action". For `confirmInteract` that means confirming. For a mode that newly denies the delegate tool, the session can no longer run at all, and the spec doesn't say what happens to it.

**Implementation:** the session ends before its next action as `permission-revoked`.

**Suggest:** name the ending for a session whose computer use a mode revokes mid-run.

### Kept downloads from the user's browser

§ Sessions, leases, grants, and tiers lists the user's browser's downloads in the result's `downloads`, and moves a managed browser's kept files to the conversation's attachments. It doesn't say whether the user's browser's files become attachments too. They are kept in place either way.

**Implementation:** they are copied to the conversation's attachments and left where they are, so the parent reaches every kept file the same way.

**Suggest:** say whether the user's browser's downloads get an `attachment`.
