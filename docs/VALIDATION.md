# Validation

Validated locally on 2026-08-29 with Xcode 26.6 (build 17F113), Swift 6, macOS 26.6.2, and the macOS 26.5 SDK. The deployment target remains macOS 15.0.

## Automated results

Command:

```sh
./scripts/build.sh
```

Observed results:

- Debug application build: **passed**.
- Unit tests: **80 passed, 0 failed, 0 skipped**. The result bundle is `DerivedData/Logs/Test/Test-CodexDictate-2026.08.29_11-16-53-+0300.xcresult`.
- Fidelity tests cover unchanged raw-source reuse, conservative stage separation, semantic inventory flow, successful prompt-only output, model-detected omission/partial coverage/distortion/unsupported addition, deterministic protected-value loss, empty sections, exactly two repair attempts, exact raw fallback, invalid generation, long-input chunking without character loss or overlap, and repeated structuring from the same original transcript.
- The Reading Assistant regression contains all ten independent dialogue-layout facts and requirements. Each prohibited vague result—“Fix the dialogue layout,” “Preserve it as closely as possible,” “Improve readability,” and “Keep names on the left”—is rejected and replaced with the exact raw fallback.
- Structured-output transport tests confirm `gpt-5.6-terra`, low reasoning, strict JSON Schema in Responses API `text.format`, dynamic output budgets, rejection of non-completed status, one bounded retry for incomplete output, and rejection after two malformed responses.
- Protected-value fixtures cover paths, URLs, repository names, ISO dates, product/platform names, labels, identifiers, versions, percentages, acronyms, negations, and strong modal wording. A multi-feature fixture covers primary/secondary requirements, current versus desired behavior, `only`/`never`/`must`/`must not`, optional behavior, conditions, exceptions, sequence, alternatives, uncertainty, investigation, non-goals, examples, and implementation-affecting rationale.
- Existing tests continue to cover state transitions and retry recovery, modifier-only hotkey edges, Option submission gestures, the eight-minute audio limit and warning pulse rates, duration preservation after automatic stop, exact target/window/editor recovery, target safety and caret placement, multipart fields, sanitization, transcription retries, retained-clipboard recovery, Keychain-dependent controller logic, and Command+V/Return event generation.
- Diagnostic tests cover five-session eviction, process-memory lifetime, typed JSON export, stage/HTTP/retry capture, and rejection of credentials, prompts, vocabulary, transcripts, and dynamic error messages from exported data.
- Release application build: **passed**.
- Release output: `build/Release/CodexDictate.app`, universal `arm64` + `x86_64`.
- Release signing: stable local Apple Development identity with Hardened Runtime. The only Release entitlement is `com.apple.security.device.audio-input`.
- Bundle inspection: `com.personal.CodexDictate`, `LSUIElement=true`, minimum macOS 15.0, and the microphone usage string are present.
- Shared scheme: `CodexDictate.xcodeproj/xcshareddata/xcschemes/CodexDictate.xcscheme` exists and works from `xcodebuild`.

Additional checks:

- `git diff --check`, source-log scans, and tracked-file scans passed. No API key, Authorization header, audio, raw transcript, or processed prompt is logged or tracked.
- Source, test, documentation, project, and built-app scans found no embedded API key, Authorization value, private transcript fixture, persisted transcript/audio file, telemetry dependency, `xcuserdata`, or generated `.m4a` artifact.
- A separate user-owned plaintext API-key file appeared at the workspace root during validation. It is ignored by `.gitignore`, is outside all Xcode target source paths, was not imported or modified, and is not present in the built app. It should be removed by the user after the key is saved through the Keychain-backed Settings UI.
- Synthesized keyboard events use Command+V for insertion. Option-alone completion additionally generates Return after a paste-settling delay; no fidelity-pipeline route generates Return.
- The application has no separate manual structure/restructure command. Automatic post-transcription formatting is the sole prompt-generation route, and failed-audio retry feeds its recovered raw transcript into the same `TranscriptStructuringService`; there is therefore no manual bypass to test.
- Hosted tests bypass application startup services, so the suite does not register the real hotkey, read/write the user Keychain, clean live retry files, or open setup UI.

## Manual / TCC-dependent

Microphone capture, Accessibility-granted Command+V into VS Code/Codex, permission-denied fallbacks, live OpenAI credentials/network behavior, and Launch at Login require user-controlled TCC prompts, a billable API key, and an interactive login session. The automated suite intentionally uses mocked model responses and makes no paid API calls. Those items are not claimed as automated tests.

Exact remaining manual sequence:

1. Install the Release app with `./scripts/install-local.sh` and launch `/Applications/CodexDictate.app`.
2. Store a real API key in Settings and grant Microphone and Accessibility access.
3. Focus a normal VS Code field and then the Codex prompt; press Control + Option to start, then press it again to stop and paste without submission. Start another recording and tap Option alone to confirm the result is pasted and submitted with Return.
4. Exercise English, technical paths/identifiers, structured instructions, and mixed-language audio.
5. Change applications during processing and disable Accessibility to confirm both copy-only reasons.
6. Exercise invalid-key, offline, timeout/rate-limit, accidental-tap, eight-minute automatic stop and final-minute warning pulses, temporary-file cleanup, relaunch-without-history, retry, and Launch at Login behavior.
