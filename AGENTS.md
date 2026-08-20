# CodexDictate permanent constraints

- Build a native macOS helper only. Do not add Electron or a browser-based shell.
- Do not create a VS Code extension or modify/fork the Codex extension.
- Control + Option uses tap-to-toggle: one press starts recording and the next press stops it.
- Pressing Option alone while recording stops recognition, pastes the result, and then generates Return to submit it. No other workflow may generate Return or Enter.
- Store the OpenAI API key only in macOS Keychain.
- Never persist audio or transcript history. Temporary audio exists only while a request can be processed or retried.
- Do not add telemetry, analytics, or third-party crash reporting.
- Restrict automatic paste to VS Code and VS Code Insiders by default.
- Integrate directly with the OpenAI REST API using `URLSession`.
- Build and run tests after material changes.
- Never log API keys, Authorization headers, audio, raw transcripts, or processed text.
