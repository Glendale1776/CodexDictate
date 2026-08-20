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

    let settings: SettingsStore
    let permissions: PermissionService

    private let keychain: KeychainStoring
    private let hotKey: GlobalHotKeyServicing
    private let audio: AudioRecorderServicing
    private let targetService: TargetApplicationProviding
    private let transcription: TranscriptionServicing
    private let structuring: TranscriptStructuringServicing
    private let pasteService: PasteService
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

    init(
        settings: SettingsStore,
        permissions: PermissionService,
        keychain: KeychainStoring,
        hotKey: GlobalHotKeyServicing,
        audio: AudioRecorderServicing,
        targetService: TargetApplicationProviding,
        transcription: TranscriptionServicing,
        structuring: TranscriptStructuringServicing,
        pasteService: PasteService
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

    func retryLastFailedRecording() {
        guard let artifact = failedRecording, !isPipelineBusy else { return }
        Task { await process(artifact) }
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
            let decision = AudioRecordingPolicy.decision(
                duration: artifact.duration,
                reachedDurationLimit: artifact.reachedDurationLimit || reachedLimit
            )
            guard case .process = decision else {
                audio.delete(artifact.url)
                let status = decision == .rejectNoSpeech ? "No speech detected" : "Recording too short"
                try update(.cancelled, status: status)
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
            audio.delete(artifact.url)
            failedRecording = nil
            canRetryFailedRecording = false

            var finalText = result.text
            var usedRawFallback = false
            if settings.structureTranscript {
                try update(.structuring, status: "Structuring")
                let structured: Result<String, Error>
                do {
                    structured = .success(try await structuring.structure(transcript: result.text, mode: settings.structuringMode, apiKey: apiKey))
                } catch {
                    structured = .failure(error)
                }
                let outcome = StructuringFallback.result(rawTranscript: result.text, structuredResult: structured)
                finalText = outcome.text
                usedRawFallback = outcome.usedRaw
            }
            lastProcessedResult = finalText
            try update(.inserting, status: "Inserting")
            let shouldSubmit = submitAfterProcessing
            submitAfterProcessing = false
            let status = await insertOrCopy(finalText, submitAfterPaste: shouldSubmit)
            let completion = usedRawFallback ? "\(status) — Raw transcript used" : status
            try update(.completed, status: completion)
            scheduleIdleReset()
            logger.info("Dictation completed")
        } catch {
            if TranscriptionFailurePolicy.isNoSpeech(error, peakLevel: recordingPeakLevel) {
                audio.delete(artifact.url)
                failedRecording = nil
                canRetryFailedRecording = false
                submitAfterProcessing = false
                try? update(.cancelled, status: "No speech detected")
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

    private func insertOrCopy(_ text: String, submitAfterPaste: Bool) async -> String {
        permissions.refresh()
        guard let capturedTarget else {
            pasteService.copy(text)
            return CopyReason.targetChanged.status
        }
        let disposition = TargetSafety.disposition(
            original: capturedTarget,
            current: targetService.currentFrontmostTarget(),
            finalText: text,
            automaticPaste: settings.automaticPaste,
            vscodeOnly: settings.vscodeOnly,
            accessibilityGranted: permissions.accessibilityGranted
        )
        switch disposition {
        case .copy(let reason):
            pasteService.copy(text)
            return reason.status
        case .paste:
            do {
                try pasteService.paste(text)
                if submitAfterPaste {
                    do {
                        try await pasteService.submitAfterPaste()
                        return "Pasted and submitted"
                    } catch {
                        return "Pasted — submit unavailable"
                    }
                }
                return "Pasted"
            } catch {
                pasteService.copy(text)
                return "Copied — paste unavailable"
            }
        }
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
        try machine.transition(to: phase, status: status, detail: detail)
        state = machine.state
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
        if !keepFailedState { scheduleIdleReset() }
    }

    private func resetToIdleIfNeeded() {
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

    private func scheduleIdleReset() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task<Never, Never>.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            self?.machine.reset()
            if let self { self.state = self.machine.state }
        }
    }
}
