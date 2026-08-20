import Foundation

struct DictationStateMachine: Sendable {
    private(set) var state = DictationState()

    enum TransitionError: Error, Equatable {
        case invalid(from: DictationPhase, to: DictationPhase)
    }

    mutating func transition(to phase: DictationPhase, status: String, detail: String? = nil) throws {
        guard Self.allowedTransitions[state.phase, default: []].contains(phase) else {
            throw TransitionError.invalid(from: state.phase, to: phase)
        }
        state = DictationState(phase: phase, status: status, detail: detail)
    }

    mutating func reset(status: String = "Ready") {
        state = DictationState(phase: .idle, status: status)
    }

    static let allowedTransitions: [DictationPhase: Set<DictationPhase>] = [
        .idle: [.recording, .transcribing, .completed, .failed],
        .recording: [.finalizingAudio, .cancelled, .failed],
        .finalizingAudio: [.transcribing, .cancelled, .failed],
        .transcribing: [.structuring, .inserting, .cancelled, .failed],
        .structuring: [.inserting, .failed],
        .inserting: [.completed, .failed],
        .completed: [.idle],
        .cancelled: [.idle],
        .failed: [.idle, .transcribing]
    ]
}
