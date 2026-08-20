# Validation

Validated locally on 2026-08-20 with Xcode 26.6 (build 17F113), Swift 6, and the macOS 26.5 SDK. The deployment target remains macOS 15.0.

## Automated results

Command:

```sh
./scripts/build.sh
```

Observed results:

- Debug application build: **passed**.
- Unit tests: **53 passed, 0 failed**. Tests cover state transitions and retry recovery, modifier-only hotkey edges, Option submission gestures, the eight-minute audio limit and warning pulse rates, duration preservation after automatic stop, target safety and caret placement, multipart fields, sanitization, JSON decoding, empty-response and transient retries, Responses output extraction, structuring fallback, clipboard serialization/restoration guards, mocked Keychain-dependent controller logic, and Command+V/Return event generation.
- Release application build: **passed**.
- Release output: `build/Release/CodexDictate.app`, universal `arm64` + `x86_64`.
- Release signing: stable local Apple Development identity with Hardened Runtime. The only Release entitlement is `com.apple.security.device.audio-input`.
- Bundle inspection: `com.personal.CodexDictate`, `LSUIElement=true`, minimum macOS 15.0, and the microphone usage string are present.
- Shared scheme: `CodexDictate.xcodeproj/xcshareddata/xcschemes/CodexDictate.xcscheme` exists and works from `xcodebuild`.

Additional checks:

- A short `open -n` launch smoke test confirmed the built Debug process starts; it then quit cleanly through the application bundle identifier.
- Source, test, documentation, project, and built-app scans found no embedded API key, Authorization value, private transcript fixture, persisted transcript/audio file, telemetry dependency, `xcuserdata`, or generated `.m4a` artifact.
- A separate user-owned plaintext API-key file appeared at the workspace root during validation. It is ignored by `.gitignore`, is outside all Xcode target source paths, was not imported or modified, and is not present in the built app. It should be removed by the user after the key is saved through the Keychain-backed Settings UI.
- Synthesized keyboard events use Command+V for insertion. Option-alone completion additionally generates Return after a paste-settling delay.
- Hosted tests bypass application startup services, so the suite does not register the real hotkey, read/write the user Keychain, clean live retry files, or open setup UI.

## Manual / TCC-dependent

Microphone capture, Accessibility-granted Command+V into VS Code/Codex, permission-denied fallbacks, live OpenAI credentials/network behavior, and Launch at Login require user-controlled TCC prompts, a billable API key, and an interactive login session. They are not claimed as automated tests.

Exact remaining manual sequence:

1. Install the Release app with `./scripts/install-local.sh` and launch `/Applications/CodexDictate.app`.
2. Store a real API key in Settings and grant Microphone and Accessibility access.
3. Focus a normal VS Code field and then the Codex prompt; press Control + Option to start, then press it again to stop and paste without submission. Start another recording and tap Option alone to confirm the result is pasted and submitted with Return.
4. Exercise English, technical paths/identifiers, structured instructions, and mixed-language audio.
5. Change applications during processing and disable Accessibility to confirm both copy-only reasons.
6. Exercise invalid-key, offline, timeout/rate-limit, accidental-tap, eight-minute automatic stop and final-minute warning pulses, temporary-file cleanup, relaunch-without-history, retry, and Launch at Login behavior.
