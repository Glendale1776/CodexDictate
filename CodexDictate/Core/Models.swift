import Foundation

enum DictationPhase: String, CaseIterable, Sendable {
    case idle
    case recording
    case finalizingAudio
    case transcribing
    case structuring
    case inserting
    case completed
    case cancelled
    case failed
}

struct DictationState: Equatable, Sendable {
    var phase: DictationPhase = .idle
    var status = "Ready"
    var detail: String?
}

struct CapturedTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let applicationName: String
    let recordingStartedAt: Date
    let windowFrame: CGRect?
    let focusedElementFrame: CGRect?
    let focusedCaretFrame: CGRect?

    init(
        processIdentifier: pid_t,
        bundleIdentifier: String?,
        applicationName: String,
        recordingStartedAt: Date,
        windowFrame: CGRect? = nil,
        focusedElementFrame: CGRect? = nil,
        focusedCaretFrame: CGRect? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.applicationName = applicationName
        self.recordingStartedAt = recordingStartedAt
        self.windowFrame = windowFrame
        self.focusedElementFrame = focusedElementFrame
        self.focusedCaretFrame = focusedCaretFrame
    }
}

struct RecordingArtifact: Equatable, Sendable {
    let url: URL
    let duration: TimeInterval
    let reachedDurationLimit: Bool
}

enum StructuringMode: String, CaseIterable, Codable, Sendable {
    case clean = "Clean"
    case structured = "Structured"

    var displayName: String {
        switch self {
        case .clean: "Clean transcript"
        case .structured: "Codex prompt"
        }
    }
}

enum DictationFailure: LocalizedError, Equatable, Sendable {
    case apiKeyMissing
    case microphoneDenied
    case accessibilityMissing
    case hotKeyConflict
    case noAudio
    case invalidRecording
    case recordingTooShort
    case durationLimit
    case processingBusy
    case targetChanged
    case pasteUnavailable
    case message(String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing: "OpenAI API key required"
        case .microphoneDenied: "Microphone permission required"
        case .accessibilityMissing: "Accessibility permission required"
        case .hotKeyConflict: "Shortcut is already in use"
        case .noAudio: "No audio captured"
        case .invalidRecording: "Recording file is invalid"
        case .recordingTooShort: "Recording was too short"
        case .durationLimit: "Recording duration limit reached"
        case .processingBusy: "Processing"
        case .targetChanged: "Target application changed"
        case .pasteUnavailable: "Paste unavailable"
        case .message(let text): text
        }
    }
}

enum CopyReason: Equatable, Sendable {
    case automaticPasteDisabled
    case targetChanged
    case targetNotAllowed
    case accessibilityRequired

    var status: String {
        switch self {
        case .automaticPasteDisabled: "Copied"
        case .targetChanged: "Copied — target changed"
        case .targetNotAllowed: "Copied — VS Code not active"
        case .accessibilityRequired: "Copied — Accessibility permission required"
        }
    }
}

enum PasteDisposition: Equatable, Sendable {
    case paste
    case copy(CopyReason)
}
