import Combine
import Foundation
import OSLog

@MainActor
final class DictationController: ObservableObject {
    @Published private(set) var state = DictationState()
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var lastRawTranscript: String?
    @Published private(set) var lastProcessedResult: String?
    @Published private(set) var canRetryFailedRecording = false
    @Published private(set) var hasAPIKey = false
    @Published private(set) var hotKeyError: String?
    @Published private(set) var diagnosticSessionCount = 0

    let settings: SettingsStore
    let permissions: PermissionService

    private let keychain: KeychainStoring
    private let hotKey: GlobalHotKeyServicing
    private let audio: AudioRecorderServicing
    private let targetService: TargetApplicationProviding
    private let transcription: TranscriptionServicing
    private let structuring: TranscriptStructuringServicing
    private let pasteService: PasteService
    private let diagnostics: DiagnosticStore
    private let logger = Logger(subsystem: "com.personal.CodexDictate", category: "Dictation")

    private var machine = DictationStateMachine()
    private var capturedTarget: CapturedTarget?
    private var failedRecording: RecordingArtifact?
    private var meterTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var recordingStartedAt: Date?
    private var recordingTransitionPending = false
    private var finishRequestedDuringStart: Bool?
    private var recordingPeakLevel: Float = 0
    private var submitAfterProcessing = false
    private var currentDiagnosticSessionID: UUID?

    init(
        settings: SettingsStore,
        permissions: PermissionService,
        keychain: KeychainStoring,
        hotKey: GlobalHotKeyServicing,
        audio: AudioRecorderServicing,
        targetService: TargetApplicationProviding,
        transcription: TranscriptionServicing,
        structuring: TranscriptStructuringServicing,
        pasteService: PasteService,
        diagnostics: DiagnosticStore = DiagnosticStore()
    ) {
        self.settings = settings
        self.permissions = permissions
        self.keychain = keychain
        self.hotKey = hotKey
        self.audio = audio
        self.targetService = targetService
        self.transcription = transcription
        self.structuring = structuring
        self.pasteService = pasteService
        self.diagnostics = diagnostics

        hotKey.onPressed = { [weak self] in self?.hotKeyPressed() }
        hotKey.onSubmitPressed = { [weak self] in self?.optionSubmitPressed() }
        audio.onMaximumDurationReached = { [weak self] in
            self?.requestFinishRecording(reachedLimit: true, submitAfterProcessing: false)
        }
        settings.onShortcutChanged = { [weak self] shortcut in self?.registerShortcut(shortcut) }
    }

    var needsFirstRunSetup: Bool {
        settings.isFirstLaunch || !hasAPIKey || permissions.microphoneStatus != .authorized || !permissions.accessibilityGranted
    }

    var indicatorTargetWindowFrame: CGRect? { capturedTarget?.windowFrame }
    var indicatorFocusedElementFrame: CGRect? { capturedTarget?.focusedElementFrame }
    var indicatorFocusedCaretFrame: CGRect? { capturedTarget?.focusedCaretFrame }

    func start() {
        audio.cleanupAbandonedRecordings()
        permissions.refresh()
        do {
            hasAPIKey = try keychain.containsKey()
        } catch {
            hasAPIKey = false
        }
        registerShortcut(settings.shortcut)
        settings.markLaunched()
    }

    func terminate() {
        meterTask?.cancel()
        resetTask?.cancel()
        audio.cancel()
        if let failedRecording { audio.delete(failedRecording.url) }
        failedRecording = nil
        audio.cleanupAbandonedRecordings()
        hotKey.unregister()
    }

    func saveAPIKey(_ key: String) -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Enter an API key" }
        do {
            try keychain.saveKey(trimmed)
            hasAPIKey = true
            return nil
        } catch {
            hasAPIKey = false
            return error.localizedDescription
        }
    }

    func deleteAPIKey() -> String? {
        do {
            try keychain.deleteKey()
            hasAPIKey = false
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func manualStartOrStop() {
        handleRecordingToggle()
    }

    func copyLastProcessed() {
        guard let lastProcessedResult else { return }
        pasteService.copy(lastProcessedResult)
        showCompletion("Copied")
    }

    func copyLastRaw() {
        guard let lastRawTranscript else { return }
        pasteService.copy(lastRawTranscript)
        showCompletion("Copied raw transcript")
    }

    func copyRecentDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let export = await diagnostics.exportJSON()
            pasteService.copy(export)
            if !isPipelineBusy { showCompletion("Copied recent diagnostics") }
        }
    }

    func retryLastFailedRecording() {
        guard let artifact = failedRecording, !isPipelineBusy else { return }
        Task {
            if let currentDiagnosticSessionID {
                await diagnostics.resume(sessionID: currentDiagnosticSessionID)
            }
            await process(artifact)
        }
    }

    private var isPipelineBusy: Bool {
        switch state.phase {
        case .recording, .finalizingAudio, .transcribing, .structuring, .inserting: true
        default: false
        }
    }

    private func hotKeyPressed() {
        handleRecordingToggle()
    }

    private func optionSubmitPressed() {
        if recordingTransitionPending {
            finishRequestedDuringStart = true
            return
        }
        guard state.phase == .recording else { return }
        logger.info("Option stop-and-submit requested")
        requestFinishRecording(reachedLimit: false, submitAfterProcessing: true)
    }

    private func handleRecordingToggle() {
        if recordingTransitionPending {
            finishRequestedDuringStart = false
            return
        }
        switch HotKeyTogglePolicy.action(
            for: state.phase,
            recordingStartPending: recordingTransitionPending
        ) {
        case .beginRecording:
            recordingTransitionPending = true
            resetToIdleIfNeeded()
            Task { await beginRecording() }
        case .endRecording:
            requestFinishRecording(reachedLimit: false, submitAfterProcessing: false)
        case .showBusy:
            showTransientStatus("Processing")
        case .ignore:
            break
        }
    }

    private func requestFinishRecording(reachedLimit: Bool, submitAfterProcessing: Bool) {
        guard state.phase == .recording, !recordingTransitionPending else { return }
        recordingTransitionPending = true
        self.submitAfterProcessing = submitAfterProcessing
        try? hotKey.setOptionSubmitEnabled(false)
        Task { await finishRecording(reachedLimit: reachedLimit) }
    }

    private func beginRecording() async {
        defer {
            recordingTransitionPending = false
            if state.phase == .recording, let shouldSubmit = finishRequestedDuringStart {
                finishRequestedDuringStart = nil
                requestFinishRecording(reachedLimit: false, submitAfterProcessing: shouldSubmit)
            } else {
                finishRequestedDuringStart = nil
            }
        }
        guard state.phase == .idle else { return }
        if permissions.microphoneStatus == .notDetermined {
            guard await permissions.requestMicrophone() else {
                fail(DictationFailure.microphoneDenied)
                return
            }
        }
        guard state.phase == .idle else { return }
        guard permissions.microphoneStatus == .authorized else {
            fail(DictationFailure.microphoneDenied)
            return
        }
        if let failedRecording {
            audio.delete(failedRecording.url)
            self.failedRecording = nil
            canRetryFailedRecording = false
        }
        currentDiagnosticSessionID = nil
        submitAfterProcessing = false
        recordingPeakLevel = 0
        guard let target = targetService.captureFrontmostTarget(at: Date()) else {
            fail(DictationFailure.message("Could not identify the target application"))
            return
        }
        do {
            try audio.start()
            do {
                try hotKey.setOptionSubmitEnabled(true)
            } catch {
                audio.cancel()
                throw error
            }
            capturedTarget = target
            recordingStartedAt = Date()
            let context = DiagnosticSessionContext(
                targetBundleIdentifier: target.bundleIdentifier,
                targetApplicationName: target.applicationName,
                targetProcessIdentifier: target.processIdentifier,
                capturedWindow: target.capturedWindowReference,
                capturedEditableElement: target.capturedEditableElementReference,
                capturedCaret: target.focusedCaretFrame != nil,
                capturedExactFocus: target.capturedWindowReference && target.capturedEditableElementReference,
                automaticPaste: settings.automaticPaste,
                restrictPasteToVSCode: settings.vscodeOnly,
                formattingEnabled: settings.structureTranscript,
                formattingMode: settings.structuringMode.rawValue,
                microphoneGranted: permissions.microphoneStatus == .authorized,
                accessibilityGranted: permissions.accessibilityGranted
            )
            currentDiagnosticSessionID = await diagnostics.beginSession(context: context)
            diagnosticSessionCount = await diagnostics.sessionCount()
            try update(.recording, status: "Recording")
            startMetering()
            logger.info("Recording started")
        } catch {
            fail(error)
        }
    }

    private func finishRecording(reachedLimit: Bool) async {
        guard state.phase == .recording else {
            recordingTransitionPending = false
            return
        }
        recordingTransitionPending = false
        try? hotKey.setOptionSubmitEnabled(false)
        meterTask?.cancel()
        meterTask = nil
        do {
            try update(.finalizingAudio, status: reachedLimit ? "Finalizing — duration limit" : "Finalizing audio")
            let artifact = try audio.stop()
            recordingDuration = artifact.duration
            audioLevel = 0
            let recordedByteCount = try? artifact.url.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize
            await recordDiagnostic(DiagnosticEvent(
                name: .recordingMetrics,
                stage: .recording,
                outcome: .success,
                durationMilliseconds: max(0, Int(artifact.duration * 1_000)),
                byteCount: recordedByteCount,
                submitRequested: submitAfterProcessing,
                stopTrigger: reachedLimit
                    ? .durationLimit
                    : (submitAfterProcessing ? .optionSubmit : .controlOption),
                reachedDurationLimit: artifact.reachedDurationLimit || reachedLimit
            ))
            let decision = AudioRecordingPolicy.decision(
                duration: artifact.duration,
                reachedDurationLimit: artifact.reachedDurationLimit || reachedLimit
            )
            guard case .process = decision else {
                audio.delete(artifact.url)
                let status = decision == .rejectNoSpeech ? "No speech detected" : "Recording too short"
                try update(.cancelled, status: status)
                await diagnostics.finish(sessionID: currentDiagnosticSessionID, outcome: .cancelled)
                scheduleIdleReset()
                return
            }
            await process(artifact)
        } catch {
            audio.cancel()
            fail(error)
        }
    }

    private func process(_ artifact: RecordingArtifact) async {
        let sessionID = currentDiagnosticSessionID
        await DiagnosticContext.$sessionID.withValue(sessionID) {
            await processWithinDiagnosticContext(artifact)
        }
    }

    private func processWithinDiagnosticContext(_ artifact: RecordingArtifact) async {
        do {
            if state.phase == .failed { try update(.transcribing, status: "Retrying transcription") }
            else { try update(.transcribing, status: "Transcribing") }
            guard let apiKey = try keychain.readKey(), !apiKey.isEmpty else { throw DictationFailure.apiKeyMissing }
            let keywords = try KeywordSanitizer.sanitize(settings.vocabularyEntries)
            let result = try await transcription.transcribe(
                audioURL: artifact.url,
                keywords: keywords,
                languages: settings.languageEntries,
                apiKey: apiKey
            )
            lastRawTranscript = result.text
            await recordDiagnostic(DiagnosticEvent(
                name: .stageCompleted,
                stage: .transcription,
                outcome: .success,
                characterCount: result.text.count,
                itemCount: result.languages.count
            ))
            audio.delete(artifact.url)
            failedRecording = nil
            canRetryFailedRecording = false

            var finalText = result.text
            var usedRawFallback = false
            if settings.structureTranscript {
                try update(.structuring, status: "Structuring")
                let structured: Result<TranscriptStructuringResult, Error>
                do {
                    structured = .success(try await structuring.structure(transcript: result.text, mode: settings.structuringMode, apiKey: apiKey))
                } catch {
                    structured = .failure(error)
                }
                let outcome = StructuringFallback.result(rawTranscript: result.text, structuredResult: structured)
                finalText = outcome.text
                usedRawFallback = outcome.usedRaw
            }
            await recordDiagnostic(DiagnosticEvent(
                name: .stageCompleted,
                stage: .generation,
                outcome: usedRawFallback ? .fallback : .success,
                characterCount: finalText.count
            ))
            lastProcessedResult = finalText
            try update(.inserting, status: "Inserting")
            let shouldSubmit = submitAfterProcessing
            submitAfterProcessing = false
            let insertion = await insertOrCopy(finalText, submitAfterPaste: shouldSubmit)
            let completion = usedRawFallback ? "\(insertion.status) — Raw transcript used" : insertion.status
            try update(.completed, status: completion)
            await diagnostics.finish(sessionID: currentDiagnosticSessionID, outcome: insertion.outcome)
            scheduleIdleReset()
            logger.info("Dictation completed")
        } catch {
            if TranscriptionFailurePolicy.isNoSpeech(error, peakLevel: recordingPeakLevel) {
                audio.delete(artifact.url)
                failedRecording = nil
                canRetryFailedRecording = false
                submitAfterProcessing = false
                try? update(.cancelled, status: "No speech detected")
                await diagnostics.finish(sessionID: currentDiagnosticSessionID, outcome: .cancelled)
                scheduleIdleReset()
                return
            }
            if (error as? OpenAIError) == .emptyTranscript {
                logger.notice("Empty transcription response despite detected speech; recording retained")
            }
            failedRecording = artifact
            canRetryFailedRecording = true
            fail(error, keepFailedState: true)
        }
    }

    private struct InsertionResult {
        let status: String
        let outcome: DiagnosticOutcome
    }

    private func insertOrCopy(_ text: String, submitAfterPaste: Bool) async -> InsertionResult {
        permissions.refresh()
        guard let intendedTarget = capturedTarget else {
            pasteService.copy(text)
            await recordDiagnostic(DiagnosticEvent(
                name: .insertionDecision,
                stage: .insertion,
                outcome: .targetChanged,
                submitRequested: submitAfterPaste
            ))
            await recordDiagnostic(DiagnosticEvent(
                name: .clipboardWrite,
                stage: .insertion,
                outcome: .success,
                characterCount: text.count
            ))
            logger.notice("Insertion copied because no intended target was available")
            return InsertionResult(status: CopyReason.targetChanged.status, outcome: .copy)
        }
        var currentTarget = targetService.currentFrontmostTarget()
        var disposition = TargetSafety.disposition(
            original: intendedTarget,
            current: currentTarget,
            finalText: text,
            automaticPaste: settings.automaticPaste,
            vscodeOnly: settings.vscodeOnly,
            accessibilityGranted: permissions.accessibilityGranted
        )
        await recordDiagnostic(DiagnosticEvent(
            name: .targetCheck,
            stage: .insertion,
            outcome: diagnosticOutcome(for: disposition),
            activeBundleIdentifier: currentTarget?.bundleIdentifier,
            submitRequested: submitAfterPaste
        ))

        // The application identity is not enough when several VS Code/Codex windows
        // exist. Both shortcut workflows target the exact window and editor captured
        // for delivery; only Option-submit is allowed to generate Return afterward.
        if TargetRecoveryPolicy.shouldRestoreExactTarget(disposition: disposition),
           !targetService.isFocused(intendedTarget) {
            logger.info("Restoring the exact captured window for automatic paste")
            let restored = await restoreFocus(to: intendedTarget)
            await recordDiagnostic(DiagnosticEvent(
                name: .focusRestoration,
                stage: .insertion,
                outcome: restored ? .success : .failure,
                activeBundleIdentifier: targetService.currentFrontmostTarget()?.bundleIdentifier
            ))
            currentTarget = targetService.currentFrontmostTarget()
            disposition = TargetSafety.disposition(
                original: intendedTarget,
                current: currentTarget,
                finalText: text,
                automaticPaste: settings.automaticPaste,
                vscodeOnly: settings.vscodeOnly,
                accessibilityGranted: permissions.accessibilityGranted
            )
        }

        // Chromium/Electron can briefly report a helper or no frontmost process while
        // its editor is committing focus. Give it a bounded chance to settle before
        // falling back to the clipboard.
        if disposition == .copy(.targetChanged) {
            for delay in [150_000_000, 350_000_000] as [UInt64] {
                try? await Task<Never, Never>.sleep(nanoseconds: delay)
                currentTarget = targetService.currentFrontmostTarget()
                disposition = TargetSafety.disposition(
                    original: intendedTarget,
                    current: currentTarget,
                    finalText: text,
                    automaticPaste: settings.automaticPaste,
                    vscodeOnly: settings.vscodeOnly,
                    accessibilityGranted: permissions.accessibilityGranted
                )
                if disposition != .copy(.targetChanged) { break }
            }
        }

        if disposition == .paste, !targetService.isFocused(intendedTarget) {
            // Application-level validation must never permit Command-V into a
            // different VS Code window when exact-window restoration did not succeed.
            disposition = .copy(.targetChanged)
        }
        switch disposition {
        case .copy(let reason):
            pasteService.copy(text)
            await recordDiagnostic(DiagnosticEvent(
                name: .insertionDecision,
                stage: .insertion,
                outcome: diagnosticOutcome(for: reason),
                characterCount: text.count,
                activeBundleIdentifier: currentTarget?.bundleIdentifier,
                submitRequested: submitAfterPaste
            ))
            await recordDiagnostic(DiagnosticEvent(
                name: .clipboardWrite,
                stage: .insertion,
                outcome: .success,
                characterCount: text.count
            ))
            logger.notice("Insertion copied instead of pasted: \(reason.status, privacy: .public)")
            return InsertionResult(status: reason.status, outcome: .copy)
        case .paste:
            do {
                try pasteService.paste(text)
                await recordDiagnostic(DiagnosticEvent(
                    name: .clipboardWrite,
                    stage: .insertion,
                    outcome: .success,
                    characterCount: text.count
                ))
                await recordDiagnostic(DiagnosticEvent(
                    name: .commandV,
                    stage: .insertion,
                    outcome: .posted,
                    submitRequested: submitAfterPaste
                ))
                if submitAfterPaste {
                    do {
                        logger.info("Waiting for pasted text to settle before Return")
                        try await pasteService.submitAfterPaste { [weak self] in
                            guard let self,
                                  await self.restoreFocus(to: intendedTarget) else {
                                throw DictationFailure.targetChanged
                            }
                        }
                        await recordDiagnostic(DiagnosticEvent(name: .returnKey, stage: .submission, outcome: .posted))
                        logger.info("Return generated for Option stop-and-submit")
                        return InsertionResult(status: "Pasted and submitted", outcome: .submitted)
                    } catch {
                        await recordDiagnostic(DiagnosticEvent(
                            name: .returnKey,
                            stage: .submission,
                            outcome: .submitUnavailable,
                            errorCode: DiagnosticErrorSanitizer.code(for: error)
                        ))
                        logger.error("Return generation failed after paste")
                        return InsertionResult(status: "Pasted — submit unavailable", outcome: .submitUnavailable)
                    }
                }
                await recordDiagnostic(DiagnosticEvent(
                    name: .insertionDecision,
                    stage: .insertion,
                    outcome: .paste,
                    submitRequested: false
                ))
                return InsertionResult(status: "Pasted", outcome: .paste)
            } catch {
                pasteService.copy(text)
                await recordDiagnostic(DiagnosticEvent(
                    name: .commandV,
                    stage: .insertion,
                    outcome: .pasteUnavailable,
                    errorCode: DiagnosticErrorSanitizer.code(for: error),
                    submitRequested: submitAfterPaste
                ))
                await recordDiagnostic(DiagnosticEvent(
                    name: .clipboardWrite,
                    stage: .insertion,
                    outcome: .success,
                    characterCount: text.count
                ))
                logger.error("Command-V generation failed; result copied")
                return InsertionResult(status: "Copied — paste unavailable", outcome: .pasteUnavailable)
            }
        }
    }

    private func restoreFocus(to target: CapturedTarget) async -> Bool {
        if targetService.isFocused(target) { return true }
        guard targetService.activate(target) else { return false }
        for _ in 0..<12 {
            try? await Task<Never, Never>.sleep(nanoseconds: 150_000_000)
            if targetService.isFocused(target) {
                // A Space/window activation can report focused just before its
                // Electron editor is ready to consume synthesized keyboard events.
                // Require the exact editor to remain focused for one more interval.
                try? await Task<Never, Never>.sleep(nanoseconds: 150_000_000)
                if targetService.isFocused(target) { return true }
            }
        }
        return false
    }

    private func startMetering() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.state.phase == .recording {
                self.recordingDuration = Date().timeIntervalSince(self.recordingStartedAt ?? Date())
                self.audioLevel = self.audio.normalizedLevel()
                self.recordingPeakLevel = max(self.recordingPeakLevel, self.audioLevel)
                try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func registerShortcut(_ shortcut: HotKeyShortcut) {
        do {
            try hotKey.register(shortcut)
            hotKeyError = nil
        } catch {
            hotKeyError = error.localizedDescription
            showTransientStatus("Shortcut conflict")
        }
    }

    private func update(_ phase: DictationPhase, status: String, detail: String? = nil) throws {
        switch phase {
        case .recording, .finalizingAudio, .transcribing, .structuring, .inserting:
            resetTask?.cancel()
            resetTask = nil
        default:
            break
        }
        try machine.transition(to: phase, status: status, detail: detail)
        state = machine.state
        let event = DiagnosticEvent(name: .phaseChanged, phase: phase.rawValue)
        let sessionID = currentDiagnosticSessionID
        Task { await diagnostics.record(event, sessionID: sessionID) }
    }

    private func fail(_ error: Error, keepFailedState: Bool = false) {
        meterTask?.cancel()
        recordingTransitionPending = false
        try? hotKey.setOptionSubmitEnabled(false)
        audioLevel = 0
        let message = (error as? LocalizedError)?.errorDescription ?? "Dictation failed"
        do {
            try machine.transition(to: .failed, status: message)
            state = machine.state
        } catch {
            machine.reset(status: message)
            state = machine.state
        }
        logger.error("Dictation pipeline failed")
        let sessionID = currentDiagnosticSessionID
        let diagnosticErrorCode = DiagnosticErrorSanitizer.code(for: error)
        Task {
            await diagnostics.record(DiagnosticEvent(
                name: .stageFailed,
                outcome: .failure,
                phase: DictationPhase.failed.rawValue,
                errorCode: diagnosticErrorCode
            ), sessionID: sessionID)
            await diagnostics.finish(sessionID: sessionID, outcome: .failure)
        }
        // A retained artifact remains retryable independently of the visible state.
        // Never leave the orange processing/failure indicator on screen indefinitely.
        scheduleIdleReset(delayNanoseconds: keepFailedState ? 2_500_000_000 : 1_500_000_000)
    }

    private func resetToIdleIfNeeded() {
        resetTask?.cancel()
        resetTask = nil
        guard state.phase != .idle else { return }
        machine.reset()
        state = machine.state
    }

    private func showTransientStatus(_ text: String) {
        if state.phase == .idle { state.status = text }
        Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: 800_000_000)
            if self?.state.phase == .idle { self?.state.status = "Ready" }
        }
    }

    private func showCompletion(_ text: String) {
        resetToIdleIfNeeded()
        do { try update(.completed, status: text) } catch { state.status = text }
        scheduleIdleReset()
    }

    private func scheduleIdleReset(delayNanoseconds: UInt64 = 1_500_000_000) {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.machine.reset()
            if let self { self.state = self.machine.state }
        }
    }

    private func recordDiagnostic(_ event: DiagnosticEvent) async {
        await diagnostics.record(event, sessionID: currentDiagnosticSessionID)
    }

    private func diagnosticOutcome(for disposition: PasteDisposition) -> DiagnosticOutcome {
        switch disposition {
        case .paste: .paste
        case .copy(let reason): diagnosticOutcome(for: reason)
        }
    }

    private func diagnosticOutcome(for reason: CopyReason) -> DiagnosticOutcome {
        switch reason {
        case .automaticPasteDisabled: .automaticPasteDisabled
        case .targetChanged: .targetChanged
        case .targetNotAllowed: .targetNotAllowed
        case .accessibilityRequired: .accessibilityRequired
        }
    }
}
