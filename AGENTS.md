# SwiftAgentHarness Agent Guidelines

## Language and Concurrency

- Use Swift 6 language mode and strict concurrency.
- Prefer modern Swift best practices, including structured concurrency and `async`/`await`.
- Avoid legacy callback-based APIs in new code unless required by an external dependency.

## Harness Template

- The `harness-template` folder contains a thoroughly researched spec that should be considered locked and read-only. The goal of this project it to produce a faithfully spec-aligned implementation of the contents of the Harness Template. Should and spec related inconsistancies, issues, or bugs be found, you are to summarize them in a document for further review.

## Testing Requirements

- All new code must include tests.
- TDD is preferred: write or update tests first, then implement.
- Add unit and integration tests as appropriate for the behavior being introduced.

#### Running the Test Suite
- Do **not** pipe `swift test` through `tail` or `head` when monitoring progress or diagnosing hangs. Those commands buffer output until the run finishes, which can make a healthy multi-minute suite look stuck.
- Prefer streaming output: `swift test` or `swift test -v`.
- To keep a log while still seeing live output, use `tee`: `swift test 2>&1 | tee /tmp/swift-test.log`.
- For focused work, filter first: `swift test --filter 'SomeTestSuite'`.
- A likely hang is **no new output for >60s and ~0% CPU** on the test runner. Silence alone often just means buffered or piped output.

#### Hanging Tests
We frequently encounter hanging tests due to the complexity of the project and the amount of shared state. Under normal conditions all tests should run in under a minute. If it's taking longer than a minute there is a good change that the tests have hung. Also if you encounter the message:
```
Another instance of SwiftPM (PID: XXXXX) is already running using '/Path/To/Project/.build', waiting until that process has finished execution...
```
That is a good indication that a former test run wan hung and not killed correctly. If you encounter these conditions, kill all of the SwiftPM test instances before running. Try to identify and fix the hanging test.

#### Flaky Tests
In order to avoid flaky tests it is important that tests do not depend on shared state. Unless absolutely necessary all tests should be able to be run in parallel and in any order. If a test is found to be flaky, the correct solution is almost always to eliminate shared state.

## Definition of Done

- A feature is not complete unless all tests pass.
- Run the full project test suite before considering work complete.

## Conventions

- Perfer to use EasyJSON instead of `[String: Any]`, `[String: Sendable]`, or `[String: String]`
- Follow Swift 6 strict concurrency
- Use Swift @Observable over ObservableObject
- Use code comments sparingly and only for non obvious implementations, gotchas, etc. (SwiftDoc-style documentation are the exception). Never referece plans or other non-code documents in code comments.
- **Tool descriptions** — Treat `ToolDefinition.description` and model-facing parameter `description` fields as prompt text. Do not reword for style without stating behavioral intent. When changing descriptions, document affected tool names and rationale in the PR/commit message.

## Antipatterns

- Never User `@unchecked sendable` to solve a swift 6 concurrency issue unless the object truely implements it's own thread safety guarantees. When `@unchecked sendable` is required, make sure to add code comments explaining why it's required and how it lives up to the `Sendable` guarantee
