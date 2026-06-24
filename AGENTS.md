# SwiftAgentHarness Agent Guidelines

## Language and Concurrency

- Use Swift 6 language mode and strict concurrency.
- Prefer modern Swift best practices, including structured concurrency and `async`/`await`.
- Avoid legacy callback-based APIs in new code unless required by an external dependency.

## Testing Requirements

- All new code must include tests.
- TDD is preferred: write or update tests first, then implement.
- Add unit and integration tests as appropriate for the behavior being introduced.

## Definition of Done

- A feature is not complete unless all tests pass.
- Run the full project test suite before considering work complete.

### Conventions

- Perfer to use EasyJSON instead of `[String: Any]`, `[String: Sendable]`, or `[String: String]`
- Follow Swift 6 strict concurrency
- Use Swift @Observable over ObservableObject
- Use code comments sparingly and only for non obvious implementations, gotchas, etc. (SwiftDoc-style documentation are the exception). Never referece plans or other non-code documents in code comments.

### Antipatterns

- Never User `@unchecked sendable` to solve a swift 6 concurrency issue unless the object truely implements it's own thread safety guarantees. When `@unchecked sendable` is required, make sure to add code comments explaining why it's required and how it lives up to the `Sendable` guarantee
