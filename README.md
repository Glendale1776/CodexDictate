# CodexDictate

CodexDictate is an open-source, native macOS 15+ menu-bar utility. Press **Control + Option** together, dictate a coding request, then press **Control + Option** again to stop and paste without submitting, or tap **Option** by itself to stop, paste, and submit with Return. It transcribes through the OpenAI API and can convert the transcript into a fidelity-checked Codex prompt.

## Copy, fork, or clone

Use GitHub's **Fork** button to copy the project into your own account, or clone it directly:

```sh
git clone https://github.com/Glendale1776/CodexDictate.git
cd CodexDictate
```

The repository includes [`AGENTS.md`](AGENTS.md) for Codex and other compatible coding agents, [`CLAUDE.md`](CLAUDE.md) for Claude Code, and a detailed [`LLM_GUIDE.md`](docs/LLM_GUIDE.md). Give an agent access to the repository root so it can read those instructions before changing the application.

> [!IMPORTANT]
> No OpenAI API key is included in this repository. Every user must provide their own key in the app's Settings. CodexDictate saves it only in that user's macOS Keychain; `.env` files and common local key-file names are ignored by Git. Never commit a key, paste it into an issue, or share it with a coding agent.

## Build

Install Xcode 26, then run:

```sh
./scripts/build.sh
```

The script builds Debug, runs unit tests, and creates a locally signed Release build under `build/Release/`. It uses `/Applications/Xcode.app` automatically when the active developer directory points at Command Line Tools. When a code-signing identity is available in Keychain, the Release app is re-signed with that stable identity so Accessibility consent survives rebuilds. Set `CODEXDICTATE_SIGNING_IDENTITY` to override the automatically selected identity.

To copy the Release application into `/Applications`, explicitly run:

```sh
./scripts/install-local.sh
```

There is no preconfigured developer team and no shared signing certificate. A local build uses a signing identity already available on the builder's Mac when possible; otherwise it is ad-hoc signed.

Local signing is intentionally automatic and no development team is hardcoded. If no identity is available, the build remains ad-hoc signed and prints a warning that Accessibility must be granted again after the app changes.

## First run

1. Launch `CodexDictate.app`; it remains in the menu bar and has no Dock icon.
2. Open **Settings**, enter an OpenAI API key, and choose **Save Key**. The key is stored as a non-synchronizing generic-password item in macOS Keychain—not in preferences or source files. OpenAI API usage is billed separately from ChatGPT subscriptions.
3. Grant **Microphone** permission when requested or from System Settings → Privacy & Security → Microphone.
4. Grant **Accessibility** permission in System Settings → Privacy & Security → Accessibility. This is needed only to synthesize Command+V; without it, results are safely copied to the clipboard.
5. Focus the Codex prompt in VS Code, press **Control + Option**, and speak. Press **Control + Option** again to stop and paste without submission. Tap **Option** by itself instead when you want CodexDictate to stop, paste the recognized prompt, and send Return automatically.

The recording indicator is a 90×1.25-point line immediately below the insertion caret in the editable field where dictation began, so it follows the cursor's horizontal position and current line in both left-to-right and right-to-left text. For web editors that do not expose an empty caret rectangle, CodexDictate derives the insertion position from neighboring text or the leading edge for the active input direction. If the field frame is unavailable, it appears just above the bottom edge of the focused window; if the window frame is also unavailable, it falls back to the bottom-center of the monitor containing the pointer. Red means recording and orange means processing or failure. Recordings stop and proceed to transcription automatically at eight minutes. The red line pulses during the final minute and doubles its pulse rate for the final 15 seconds.

The first launch opens the same compact setup-oriented Settings window when a key or permission is missing. A test recording can be started from the menu after the microphone permission is granted.

## Settings and recovery

- Click the shortcut field and press Control + Option together, or enter a key combination containing Option, Control, or Command. Shift by itself is rejected.
- Choose Clean transcript or adaptive Codex prompt formatting, disable formatting, edit technical vocabulary, or provide expected language codes. Both formatting modes use the same fidelity pipeline: conservative normalization, an atomic semantic inventory, prompt generation, independent verification, deterministic protected-value checks, and at most two targeted repairs. Codex prompt formatting adds only sections supported by the dictation.
- Paths, URLs, repository names, dates, product/platform names, quoted labels, code identifiers, versions, numbers, acronyms, negations, and strong modal terms are protected against silent loss or change. Long input is partitioned at safe text boundaries before inventories are merged.
- If structured output is malformed, incomplete, empty, or still fails verification after two repairs, CodexDictate pastes `DICTATED REQUEST:` followed by the unchanged raw transcript instead of returning a polished but incomplete request. The completion status says **Raw transcript used**; internal inventories and verifier diagnostics never enter the clipboard result.
- Automatic paste is VS Code-only by default. Enabling other applications is an explicit advanced choice.
- The menu bar icon can be hidden from **Settings → Advanced**. Reopen CodexDictate from `/Applications` to show Settings again while the icon is hidden.
- **Copy Last Result** and **Copy Last Raw Transcript** recover the latest in-memory result. Nothing is retained after quit.
- **Copy Recent Diagnostics** copies a privacy-safe JSON timeline for the five most recent dictation sessions. It records phases, durations, bounded retries, HTTP status codes, formatting/verification outcomes, captured-target checks, focus restoration, clipboard writes, Command+V, and Option-submit Return posting. The buffer exists only in memory and excludes audio, file paths, API credentials, transcript/prompt/clipboard text, document contents, and window titles.
- After any successful insertion attempt, the complete result remains on the clipboard. macOS does not acknowledge whether a Chromium/Electron field accepted a synthesized Command+V, so this guarantees that a missed automatic paste can still be recovered with Command+V.
- Empty transcription responses are retried automatically once. A failed transcription with detected speech may be retried from the menu while its temporary recording remains available.
- Launch at Login uses the system `SMAppService` registration.

## Permission troubleshooting

Permissions are associated with both the bundle identifier `com.personal.CodexDictate` and the app's designated code requirement. If System Settings shows an enabled CodexDictate row while the app says Accessibility is required, reset the stale entry with `tccutil reset Accessibility com.personal.CodexDictate`, relaunch `/Applications/CodexDictate.app`, click **Request**, and enable the newly created row. During ad-hoc development, Microphone can likewise be reset with `tccutil reset Microphone com.personal.CodexDictate`.

CodexDictate is intended for personal local use. Audio and text go directly from the Mac to OpenAI; there is no separate backend, transcript history, telemetry, remotely collected analytics, or local Whisper installation. The optional five-session diagnostic timeline is local, memory-only metadata.

## Documentation and license

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) explains the major components and data flow.
- [`docs/LLM_GUIDE.md`](docs/LLM_GUIDE.md) maps common questions and changes to the relevant source files.
- [`docs/VALIDATION.md`](docs/VALIDATION.md) records automated and manual validation coverage.
- [`LICENSE`](LICENSE) makes the source available under the MIT License.
