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
