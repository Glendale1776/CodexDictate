# Coding-agent guide

This document helps Codex, Claude Code, and other repository-aware assistants answer questions and make safe changes without reverse-engineering the project from scratch. The source code remains authoritative. Read `AGENTS.md` first; its privacy, input, platform, and testing constraints are mandatory.

## What the application does

CodexDictate is a native Swift/AppKit and SwiftUI macOS menu-bar helper. It captures a modifier-only global shortcut, records microphone audio into a temporary file, sends that file directly to OpenAI for transcription, optionally transforms the transcript into a fidelity-checked coding prompt, then restores the originally captured editor and pastes the result.

It has no server, browser shell, VS Code extension, account system, analytics, transcript database, or third-party runtime dependency. The user's OpenAI key is a local macOS Keychain item. Audio is temporary, and transcript/result recovery is memory-only until the app quits.

## User-visible controls

- Press **Control + Option** while idle to begin recording.
- Press **Control + Option** while recording to stop, process, and paste without submitting.
- Press **Option alone** while recording to stop, process, paste, and then synthesize Return. This is the only path allowed to generate Return.
- Use the menu-bar item for Settings, test recording, retry after eligible audio failures, copying the last in-memory result/raw transcript, copying privacy-safe diagnostics, and quitting.
- By default, automatic paste is restricted to VS Code (`com.microsoft.VSCode`) and VS Code Insiders (`com.microsoft.VSCodeInsiders`). Other targets require an explicit advanced preference.

## Runtime flow and source map

1. `CodexDictate/App/AppDelegate.swift` creates the menu-bar UI, settings window, services, and application lifecycle.
2. `CodexDictate/HotKey/GlobalHotKeyService.swift` and `CodexDictate/Core/HotKeyEdgeTracker.swift` translate modifier edges into toggle or Option-submit gestures.
3. `CodexDictate/Core/DictationController.swift` is the main-actor orchestration boundary. `DictationStateMachine.swift` defines valid, non-overlapping phases.
4. `CodexDictate/System/TargetApplicationService.swift` captures the frontmost process, window, and editable Accessibility element at recording start and revalidates them before insertion.
5. `CodexDictate/Audio/AudioRecorderService.swift` records mono AAC in a dedicated temporary directory. `AudioRecordingPolicy.swift` owns duration and warning rules.
6. `CodexDictate/Security/KeychainService.swift` reads and writes the non-synchronizing generic-password item. Never replace this with source, environment, or preferences storage.
7. `CodexDictate/Networking/OpenAIClient.swift` performs redaction-safe `URLSession` requests. `TranscriptionServices.swift` builds the transcription request; `FidelityPipeline.swift`, `FidelityModels.swift`, and `FidelityInstructions.swift` implement normalization, semantic inventory, generation, verification, bounded repair, and exact raw fallback.
8. `CodexDictate/Paste/PasteService.swift` writes the full result to the clipboard, posts Command+V, and posts Return only when the controller passes the Option-submit intent.
9. `CodexDictate/UI/HUDController.swift` places the recording/processing indicator near the captured insertion caret. `SettingsView.swift` exposes key, shortcut, formatting, permissions, privacy, recovery, and advanced controls.
10. `CodexDictate/Core/Diagnostics.swift` stores a five-session, memory-only timeline containing bounded operational metadata and no user content or credentials.

## Key invariants

- Never log, persist, fixture, or commit API keys, Authorization values, audio, raw transcripts, normalized text, generated prompts, clipboard text, document contents, or window titles.
- Do not broaden keyboard submission. Return follows only a recording stopped by Option alone, after the paste-settling delay.
- Keep Control + Option as tap-to-toggle rather than press-and-hold.
- Preserve the exact captured target checks; do not paste into whatever application happens to be frontmost after network processing.
- Keep the raw transcript immutable inside the fidelity pipeline. On malformed, incomplete, empty, or repeatedly unfaithful structured output, return `DICTATED REQUEST:\n\n<raw transcript>`.
- Keep automatic paste limited to VS Code and VS Code Insiders unless the user explicitly opts into other applications.
- Use direct OpenAI REST requests through `URLSession`; do not add an SDK, backend, telemetry, or crash reporter.
- Remove temporary audio after success, cancellation, terminal failure, startup cleanup, or termination. Retain it only while an eligible request can be retried.

## Settings and stored data

`SettingsStore.swift` uses preferences only for non-secret configuration such as shortcut, formatting mode, languages, vocabulary, launch behavior, and target policy. `KeychainService.swift` is the sole API-key persistence boundary. The latest raw transcript, processed result, and diagnostic ring buffer exist only in process memory. Temporary AAC files are excluded from Git and are not history.

## Working safely

Before changing behavior, locate the corresponding tests under `CodexDictateTests/`. Add or update deterministic tests for state transitions, shortcut edges, target validation, networking decoding/retries, fidelity preservation, diagnostics privacy, paste events, and Keychain-dependent logic as applicable. Then run `./scripts/build.sh`, which builds Debug, runs unit tests, and produces a Release app.

Do not use a real API key in tests. Networking tests use injected transports and mocked responses. Microphone, Accessibility, live API, and Launch at Login behavior require the manual checks listed in `docs/VALIDATION.md`.

When answering questions without changing code, cite the relevant source file and distinguish implemented behavior from manual/TCC-dependent behavior. When changing behavior, update `README.md`, `docs/ARCHITECTURE.md`, and `docs/VALIDATION.md` when their claims are affected.
