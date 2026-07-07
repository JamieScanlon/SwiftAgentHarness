# Contributing to SwiftAgentHarness

Thanks for your interest in contributing! Contributions of all kinds are welcome — bug fixes, features, tests, and documentation (including the [harness-template](./harness-template/) design guide).

## Contributor License Agreement (required)

SwiftAgentHarness is **dual-licensed**: it is available under the [GNU AGPL v3](./LICENSE) and under commercial license terms from the project owner. To make dual licensing possible, all contributors must sign the [Individual Contributor License Agreement](./CLA.md) before their contributions can be accepted. The CLA grants the project owner the right to re-license your contributions (including commercially) while **you keep full ownership of your work** and can use it however you like.

Signing is handled automatically: when you open your first pull request, the CLA Assistant check will prompt you to sign electronically by following a link and confirming. You only need to do this once; subsequent pull requests pass the check automatically. Pull requests cannot be merged until all commit authors have signed.

If you are contributing on behalf of your employer, make sure you have permission to do so (see section 5(c) of the CLA).

## How to contribute

1. **Open an issue first** for anything non-trivial, so the approach can be agreed on before you invest time.
2. **Fork and branch.** Create a feature branch from `main`.
3. **Follow the project conventions** in [AGENTS.md](./AGENTS.md) — Swift 6 language mode, strict concurrency, structured concurrency (`async`/`await`), `EasyJSON` over untyped dictionaries, and comments only where the code is non-obvious.
4. **Include tests.** All new code must come with tests (TDD preferred). Tests must not depend on shared state and should run in parallel in any order. The full suite should finish in under a minute — a longer run usually means a hung test.
5. **Run the full test suite** (`swift test`) before opening the pull request. A feature is not complete unless all tests pass.
6. **Open a pull request** with a clear description of what changed and why. Sign the CLA when prompted.

## Questions

Open an issue, or start a discussion on the repository.
