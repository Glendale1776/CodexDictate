# Implementation plan

1. Create an Xcode 26-compatible Swift 6 macOS 15 application and shared scheme with sandboxing disabled, hardened runtime enabled, microphone entitlement, `LSUIElement`, and stable bundle identity.
2. Implement testable services for Carbon hotkeys, AVFoundation recording, temporary-file hygiene, Keychain, permissions, target capture, clipboard-safe Command+V insertion, launch-at-login, and direct OpenAI REST networking.
3. Build the central non-overlapping dictation state machine and pipeline: capture target → record → validate → transcribe → optionally structure → verify target → paste or copy → clean up.
4. Add the menu-bar UI, non-activating HUD, first-run/settings window, configurable shortcut, vocabulary/languages, permission controls, and in-memory recovery/retry actions.
5. Add deterministic tests for state transitions, hotkey edges, audio limits, multipart data, sanitization/decoding, HTTP errors/retries, structuring fallback, target safety, clipboard protection, and Keychain-dependent logic.
6. Build Debug and Release, run all tests, fix local failures, scan for secrets/privacy regressions, and record actual results in `docs/VALIDATION.md`.
