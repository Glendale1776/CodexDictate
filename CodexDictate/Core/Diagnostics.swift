import Foundation

enum DiagnosticStage: String, Codable, Sendable {
    case recording
    case transcription
    case normalization
    case inventory
    case generation
    case verification
    case repair
    case insertion
    case submission
}

enum DiagnosticEventName: String, Codable, Sendable {
    case phaseChanged = "phase_changed"
    case recordingMetrics = "recording_metrics"
    case stageStarted = "stage_started"
    case stageCompleted = "stage_completed"
    case stageFailed = "stage_failed"
    case httpResponse = "http_response"
    case retryScheduled = "retry_scheduled"
    case chunkPlan = "chunk_plan"
    case semanticInventory = "semantic_inventory"
    case verificationResult = "verification_result"
    case targetCheck = "target_check"
    case focusRestoration = "focus_restoration"
    case insertionDecision = "insertion_decision"
    case clipboardWrite = "clipboard_write"
    case commandV = "command_v"
    case returnKey = "return_key"
    case sessionResumed = "session_resumed"
    case sessionFinished = "session_finished"
}

enum DiagnosticOutcome: String, Codable, Sendable {
    case started
    case success
    case failure
    case retry
    case passed
    case failed
    case fallback
    case paste
    case copy
    case submitted
    case posted
    case cancelled
    case targetChanged = "target_changed"
    case targetNotAllowed = "target_not_allowed"
    case accessibilityRequired = "accessibility_required"
    case automaticPasteDisabled = "automatic_paste_disabled"
    case pasteUnavailable = "paste_unavailable"
    case submitUnavailable = "submit_unavailable"
}

enum DiagnosticStopTrigger: String, Codable, Sendable {
    case controlOption = "control_option"
    case optionSubmit = "option_submit"
    case durationLimit = "duration_limit"
}

struct DiagnosticEvent: Codable, Equatable, Sendable {
    let timestamp: Date
    let name: DiagnosticEventName
    let stage: DiagnosticStage?
    let outcome: DiagnosticOutcome?
    let phase: String?
    let durationMilliseconds: Int?
    let attempt: Int?
    let httpStatus: Int?
    let byteCount: Int?
    let characterCount: Int?
    let itemCount: Int?
    let errorCode: String?
    let activeBundleIdentifier: String?
    let submitRequested: Bool?
    let stopTrigger: DiagnosticStopTrigger?
    let reachedDurationLimit: Bool?

    init(
        timestamp: Date = Date(),
        name: DiagnosticEventName,
        stage: DiagnosticStage? = nil,
        outcome: DiagnosticOutcome? = nil,
        phase: String? = nil,
        durationMilliseconds: Int? = nil,
        attempt: Int? = nil,
        httpStatus: Int? = nil,
        byteCount: Int? = nil,
        characterCount: Int? = nil,
        itemCount: Int? = nil,
        errorCode: String? = nil,
        activeBundleIdentifier: String? = nil,
        submitRequested: Bool? = nil,
        stopTrigger: DiagnosticStopTrigger? = nil,
        reachedDurationLimit: Bool? = nil
    ) {
        self.timestamp = timestamp
        self.name = name
        self.stage = stage
        self.outcome = outcome
        self.phase = phase
        self.durationMilliseconds = durationMilliseconds
        self.attempt = attempt
        self.httpStatus = httpStatus
        self.byteCount = byteCount
        self.characterCount = characterCount
        self.itemCount = itemCount
        self.errorCode = errorCode
        self.activeBundleIdentifier = activeBundleIdentifier
        self.submitRequested = submitRequested
        self.stopTrigger = stopTrigger
        self.reachedDurationLimit = reachedDurationLimit
    }
}

struct DiagnosticSessionContext: Codable, Equatable, Sendable {
    let targetBundleIdentifier: String?
    let targetApplicationName: String
    let targetProcessIdentifier: Int32
    let capturedWindow: Bool
    let capturedEditableElement: Bool
    let capturedCaret: Bool
    let capturedExactFocus: Bool
    let automaticPaste: Bool
    let restrictPasteToVSCode: Bool
    let formattingEnabled: Bool
    let formattingMode: String
    let microphoneGranted: Bool
    let accessibilityGranted: Bool
}

struct DiagnosticSession: Codable, Equatable, Sendable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?
    var finalOutcome: DiagnosticOutcome?
    let context: DiagnosticSessionContext
    var events: [DiagnosticEvent]
}

struct DiagnosticExportEnvelope: Codable, Equatable, Sendable {
    struct Application: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let build: String
        let operatingSystem: String
    }

    struct Privacy: Codable, Equatable, Sendable {
        let persistence: String
        let excludedData: [String]
    }

    let schemaVersion: Int
    let generatedAt: Date
    let application: Application
    let privacy: Privacy
    let sessions: [DiagnosticSession]
}

protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent, sessionID: UUID?) async
}

enum DiagnosticContext {
    @TaskLocal static var sessionID: UUID?
}

actor DiagnosticStore: DiagnosticRecording {
    static let maximumSessionCount = 5

    private var sessions: [DiagnosticSession] = []

    func beginSession(context: DiagnosticSessionContext, at date: Date = Date()) -> UUID {
        let id = UUID()
        sessions.append(DiagnosticSession(
            id: id,
            startedAt: date,
            endedAt: nil,
            finalOutcome: nil,
            context: context,
            events: []
        ))
        if sessions.count > Self.maximumSessionCount {
            sessions.removeFirst(sessions.count - Self.maximumSessionCount)
        }
        return id
    }

    func resume(sessionID: UUID, at date: Date = Date()) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].endedAt = nil
        sessions[index].finalOutcome = nil
        sessions[index].events.append(DiagnosticEvent(
            timestamp: date,
            name: .sessionResumed,
            outcome: .retry
        ))
    }

    func record(_ event: DiagnosticEvent, sessionID: UUID?) {
        guard let sessionID,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].events.append(event)
    }

    func finish(sessionID: UUID?, outcome: DiagnosticOutcome, at date: Date = Date()) {
        guard let sessionID,
              let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].endedAt = date
        sessions[index].finalOutcome = outcome
        sessions[index].events.append(DiagnosticEvent(
            timestamp: date,
            name: .sessionFinished,
            outcome: outcome
        ))
    }

    func sessionCount() -> Int { sessions.count }

    func snapshot() -> [DiagnosticSession] {
        sessions.map { session in
            var ordered = session
            ordered.events.sort { $0.timestamp < $1.timestamp }
            return ordered
        }
    }

    func exportJSON(now: Date = Date()) -> String {
        let bundle = Bundle.main
        let envelope = DiagnosticExportEnvelope(
            schemaVersion: 1,
            generatedAt: now,
            application: .init(
                name: "CodexDictate",
                version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            privacy: .init(
                persistence: "Memory only; the five-session buffer is cleared when CodexDictate quits.",
                excludedData: [
                    "API keys and Authorization headers",
                    "audio and audio-file paths",
                    "raw transcripts",
                    "normalized transcripts",
                    "processed prompts and clipboard text",
                    "window titles and document contents"
                ]
            ),
            sessions: snapshot()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(envelope),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"schemaVersion":1,"sessions":[],"exportError":"encoding_failed"}"#
        }
        return text
    }
}

enum DiagnosticErrorSanitizer {
    static func code(for error: Error) -> String {
        if let error = error as? OpenAIError {
            return switch error {
            case .unauthorized: "openai.unauthorized"
            case .forbidden: "openai.forbidden"
            case .notFound: "openai.not_found"
            case .rateLimited: "openai.rate_limited"
            case .server(let status): "openai.server_\(status)"
            case .invalidRequest(let status): "openai.invalid_request_\(status)"
            case .timeout: "openai.timeout"
            case .networkUnavailable: "openai.network_unavailable"
            case .invalidJSON: "openai.invalid_json"
            case .emptyTranscript: "openai.empty_transcript"
            case .invalidStructuringResponse: "openai.invalid_structuring_response"
            case .invalidFile: "openai.invalid_file"
            }
        }
        if let error = error as? FidelityPipelineError {
            return "fidelity.\(String(describing: error))"
        }
        if let error = error as? AudioRecorderError {
            return "audio.\(String(describing: error))"
        }
        if let error = error as? DictationFailure {
            return switch error {
            case .apiKeyMissing: "dictation.api_key_missing"
            case .microphoneDenied: "dictation.microphone_denied"
            case .accessibilityMissing: "dictation.accessibility_missing"
            case .hotKeyConflict: "dictation.hotkey_conflict"
            case .noAudio: "dictation.no_audio"
            case .invalidRecording: "dictation.invalid_recording"
            case .recordingTooShort: "dictation.recording_too_short"
            case .durationLimit: "dictation.duration_limit"
            case .processingBusy: "dictation.processing_busy"
            case .targetChanged: "dictation.target_changed"
            case .pasteUnavailable: "dictation.paste_unavailable"
            case .message: "dictation.message"
            }
        }
        if let error = error as? KeychainError {
            return switch error {
            case .invalidEncoding: "keychain.invalid_encoding"
            case .unexpectedStatus(let status): "keychain.status_\(status)"
            }
        }
        if let error = error as? PasteEventError {
            return switch error {
            case .eventSourceUnavailable: "paste.event_source_unavailable"
            case .eventUnavailable: "paste.event_unavailable"
            }
        }
        return "unknown"
    }
}

extension FidelityStage {
    var diagnosticStage: DiagnosticStage {
        switch self {
        case .normalization: .normalization
        case .inventory: .inventory
        case .generation: .generation
        case .verification: .verification
        case .repair: .repair
        }
    }
}
