import Foundation

enum AudioRecordingDecision: Equatable, Sendable {
    case rejectTooShort
    case rejectNoSpeech
    case process(reachedDurationLimit: Bool)
}

enum AudioRecordingPolicy {
    // normalizedLevel() maps the recorder's average power logarithmically. The
    // previous threshold (-80 dB equivalent) classified ordinary microphone
    // noise as speech, so an empty recording was unnecessarily uploaded.
    static let minimumSpeechLevel: Float = 0.04

    static func decision(
        duration: TimeInterval,
        peakLevel: Float? = nil,
        reachedDurationLimit: Bool
    ) -> AudioRecordingDecision {
        guard duration >= AudioRecorderService.minimumDuration else { return .rejectTooShort }
        if let peakLevel, peakLevel < minimumSpeechLevel { return .rejectNoSpeech }
        return .process(reachedDurationLimit: reachedDurationLimit)
    }
}
