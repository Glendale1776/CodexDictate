# Architecture

CodexDictate is an `LSUIElement` AppKit application whose menu and lifecycle are coordinated by `AppDelegate`. SwiftUI supplies the Settings and HUD content, while AppKit supplies `NSStatusItem`, a non-activating `NSPanel`, pasteboard access, and application targeting.

`DictationController` is the `@MainActor` orchestration boundary. A pure `DictationStateMachine` enforces the single-pipeline phases `idle`, `recording`, `finalizingAudio`, `transcribing`, `structuring`, `inserting`, `completed`, `cancelled`, and `failed`. Modifier-edge monitors feed a `HotKeyTogglePolicy`: Control + Option toggles recording, while Option alone during recording stops, pastes, and submits with Return. Processing presses are rejected without overlapping work.

`AudioRecorderService` writes mono AAC to a dedicated temporary directory, exposes metering, preserves duration with a monotonic clock, and stops automatically after eight minutes. Startup and termination cleanup remove abandoned files. `TargetApplicationService` captures the frontmost PID/bundle at press time. `PasteService` later rechecks PID, bundle policy, and Accessibility, snapshots every pasteboard representation, sends Command+V, optionally sends Return after a settling delay, and restores the prior clipboard only if the change count remains unchanged.

`KeychainService` owns a non-synchronizing generic-password item. `SettingsStore` persists only non-secret preferences. `OpenAIClient` uses an ephemeral injected transport, typed errors, centralized models, redaction-safe logging, one bounded transient retry, and one retry for an empty transcription response. `TranscriptionService` builds multipart audio requests; `TranscriptStructuringService` parses raw Responses API output items and falls back to the successful raw transcript on structuring failure.

No transcript or result is written to disk. Only the latest raw and processed strings are held in memory until termination. There is no analytics, backend, extension, broad keyboard event tap, or third-party runtime dependency.
