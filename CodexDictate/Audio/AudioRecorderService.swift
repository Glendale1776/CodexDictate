import AVFoundation
import Foundation

@MainActor
protocol AudioRecorderServicing: AnyObject {
    var onMaximumDurationReached: (() -> Void)? { get set }
    var isRecording: Bool { get }
    func start() throws
    func stop() throws -> RecordingArtifact
    func cancel()
    func normalizedLevel() -> Float
    func delete(_ url: URL)
    func cleanupAbandonedRecordings()
}

enum AudioRecorderError: LocalizedError, Equatable {
    case alreadyRecording
    case notRecording
    case couldNotCreateFile
    case noAudio
    case fileTooLarge

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress"
        case .notRecording: "No recording is in progress"
        case .couldNotCreateFile: "The recording could not be created"
        case .noAudio: "No audio captured"
        case .fileTooLarge: "The recording exceeds the upload limit"
        }
    }
}

@MainActor
final class AudioRecorderService: NSObject, AudioRecorderServicing, @preconcurrency AVAudioRecorderDelegate {
    nonisolated static let minimumDuration: TimeInterval = 0.25
    // Bound recording and upload time. Prompt generation separately uses dynamic
    // output budgets and fidelity-preserving chunking rather than a 4,096-token cap.
    nonisolated static let maximumDuration: TimeInterval = 8 * 60
    nonisolated static let maximumUploadBytes = 25 * 1024 * 1024

    var onMaximumDurationReached: (() -> Void)?
    private(set) var isRecording = false

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var stoppedManually = false
    private var reachedLimit = false
    private var recordingStartedUptime: TimeInterval?
    private let fileManager: FileManager
    private let recordingsDirectory: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        recordingsDirectory = fileManager.temporaryDirectory.appendingPathComponent("CodexDictateRecordings", isDirectory: true)
        super.init()
    }

    func start() throws {
        guard !isRecording else { throw AudioRecorderError.alreadyRecording }
        try fileManager.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        let url = recordingsDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record(forDuration: Self.maximumDuration) else {
            try? fileManager.removeItem(at: url)
            throw AudioRecorderError.couldNotCreateFile
        }
        self.recorder = recorder
        currentURL = url
        stoppedManually = false
        reachedLimit = false
        recordingStartedUptime = ProcessInfo.processInfo.systemUptime
        isRecording = true
    }

    func stop() throws -> RecordingArtifact {
        guard let recorder, let currentURL else { throw AudioRecorderError.notRecording }
        // AVAudioRecorder can reset currentTime when record(forDuration:) ends
        // before its delegate callback is handled. Preserve the real session
        // length with a monotonic clock so a long auto-finished recording is not
        // mistaken for an empty recording and deleted.
        let elapsed = recordingStartedUptime.map {
            max(0, ProcessInfo.processInfo.systemUptime - $0)
        } ?? 0
        let duration = AudioRecordingTiming.finalizedDuration(
            recorderDuration: recorder.currentTime,
            elapsedDuration: elapsed
        )
        stoppedManually = true
        recorder.stop()
        isRecording = false
        self.recorder = nil
        self.currentURL = nil
        recordingStartedUptime = nil

        guard fileManager.fileExists(atPath: currentURL.path) else { throw AudioRecorderError.noAudio }
        let values = try currentURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw AudioRecorderError.noAudio }
        guard size < Self.maximumUploadBytes else { throw AudioRecorderError.fileTooLarge }
        return RecordingArtifact(url: currentURL, duration: duration, reachedDurationLimit: reachedLimit)
    }

    func cancel() {
        guard let recorder else { return }
        stoppedManually = true
        recorder.stop()
        if let currentURL { try? fileManager.removeItem(at: currentURL) }
        self.recorder = nil
        currentURL = nil
        recordingStartedUptime = nil
        isRecording = false
    }

    func normalizedLevel() -> Float {
        guard let recorder, isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = recorder.averagePower(forChannel: 0)
        return max(0, min(1, pow(10, decibels / 35)))
    }

    func delete(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == recordingsDirectory.standardizedFileURL else { return }
        try? fileManager.removeItem(at: url)
    }

    func cleanupAbandonedRecordings() {
        guard let urls = try? fileManager.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension.lowercased() == "m4a" {
            try? fileManager.removeItem(at: url)
        }
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !stoppedManually else { return }
        reachedLimit = true
        isRecording = false
        onMaximumDurationReached?()
    }
}

enum AudioRecordingTiming {
    nonisolated static func finalizedDuration(
        recorderDuration: TimeInterval,
        elapsedDuration: TimeInterval
    ) -> TimeInterval {
        max(recorderDuration, elapsedDuration)
    }
}
