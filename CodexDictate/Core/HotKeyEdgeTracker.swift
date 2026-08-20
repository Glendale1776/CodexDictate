import Foundation

enum HotKeyTogglePolicy {
    enum Action: Equatable, Sendable {
        case beginRecording
        case endRecording
        case showBusy
        case ignore
    }

    static func action(for phase: DictationPhase, recordingStartPending: Bool) -> Action {
        if recordingStartPending { return .ignore }
        switch phase {
        case .recording:
            return .endRecording
        case .finalizingAudio, .transcribing, .structuring, .inserting:
            return .showBusy
        case .idle, .completed, .cancelled, .failed:
            return .beginRecording
        }
    }
}

struct OptionSubmitGestureTracker {
    private(set) var isEnabled = false
    private var blockedUntilNeutral = false
    private var optionPressCandidate = false

    mutating func setEnabled(_ enabled: Bool, currentModifiers: UInt32 = 0) {
        isEnabled = enabled
        blockedUntilNeutral = enabled && currentModifiers != 0
        optionPressCandidate = false
    }

    mutating func synchronizeNeutralState() {
        guard isEnabled else { return }
        blockedUntilNeutral = false
        optionPressCandidate = false
    }

    mutating func update(currentModifiers: UInt32) -> Bool {
        guard isEnabled else { return false }

        if blockedUntilNeutral {
            if currentModifiers == 0 { blockedUntilNeutral = false }
            return false
        }

        let option: UInt32 = 2048
        if currentModifiers == option {
            optionPressCandidate = true
            return false
        }
        if currentModifiers == 0 {
            let shouldSubmit = optionPressCandidate
            optionPressCandidate = false
            return shouldSubmit
        }

        blockedUntilNeutral = true
        optionPressCandidate = false
        return false
    }
}

struct ModifierChordEdgeTracker {
    private(set) var isActive = false

    mutating func update(currentModifiers: UInt32, requiredModifiers: UInt32) -> Bool {
        let wasActive = isActive
        isActive = currentModifiers == requiredModifiers
        return isActive && !wasActive
    }

    mutating func reset() {
        isActive = false
    }
}
