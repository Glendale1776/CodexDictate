import XCTest
@testable import CodexDictate

final class StateAndPolicyTests: XCTestCase {
    func testCompleteStateMachinePath() throws {
        var machine = DictationStateMachine()
        let phases: [DictationPhase] = [
            .recording, .finalizingAudio, .transcribing, .structuring,
            .inserting, .completed, .idle
        ]
        for phase in phases {
            if phase == .idle { machine.reset() }
            else { try machine.transition(to: phase, status: phase.rawValue) }
        }
        XCTAssertEqual(machine.state.phase, .idle)
    }

    func testStateMachineRejectsOverlappingRecording() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .recording, status: "Recording")
        XCTAssertThrowsError(try machine.transition(to: .recording, status: "Recording again")) { error in
            XCTAssertEqual(error as? DictationStateMachine.TransitionError, .invalid(from: .recording, to: .recording))
        }
    }

    func testIdleCanRetryRetainedRecordingAtTranscription() throws {
        var machine = DictationStateMachine()
        try machine.transition(to: .transcribing, status: "Retrying transcription")
        XCTAssertEqual(machine.state.phase, .transcribing)
    }

    func testHotKeyPressTogglesIdleAndRecording() {
        XCTAssertEqual(
            HotKeyTogglePolicy.action(for: .idle, recordingStartPending: false),
            .beginRecording
        )
        XCTAssertEqual(
            HotKeyTogglePolicy.action(for: .recording, recordingStartPending: false),
            .endRecording
        )
    }

    func testHotKeyPressDuringTransitionOrProcessingDoesNotStartRecording() {
        XCTAssertEqual(
            HotKeyTogglePolicy.action(for: .idle, recordingStartPending: true),
            .ignore
        )
        XCTAssertEqual(
            HotKeyTogglePolicy.action(for: .transcribing, recordingStartPending: false),
            .showBusy
        )
    }

    func testMinimumDurationIsRejected() {
        XCTAssertEqual(AudioRecordingPolicy.decision(duration: 0.249, reachedDurationLimit: false), .rejectTooShort)
        XCTAssertEqual(AudioRecordingPolicy.decision(duration: 0.25, reachedDurationLimit: false), .process(reachedDurationLimit: false))
    }

    func testMeterLevelCanIdentifySilenceWhenExplicitlyRequested() {
        XCTAssertEqual(
            AudioRecordingPolicy.decision(duration: 2, peakLevel: 0.02, reachedDurationLimit: false),
            .rejectNoSpeech
        )
        XCTAssertEqual(
            AudioRecordingPolicy.decision(duration: 2, peakLevel: 0.05, reachedDurationLimit: false),
            .process(reachedDurationLimit: false)
        )
    }

    func testStoppedRecordingRemainsProcessableWithoutLocalSpeechFiltering() {
        XCTAssertEqual(
            AudioRecordingPolicy.decision(duration: 2, reachedDurationLimit: false),
            .process(reachedDurationLimit: false)
        )
    }

    func testEmptyTranscriptionIsTreatedAsNoSpeechInsteadOfPipelineFailure() {
        XCTAssertTrue(TranscriptionFailurePolicy.isNoSpeech(OpenAIError.emptyTranscript, peakLevel: 0.01))
        XCTAssertFalse(TranscriptionFailurePolicy.isNoSpeech(OpenAIError.emptyTranscript, peakLevel: 0.1))
        XCTAssertFalse(TranscriptionFailurePolicy.isNoSpeech(OpenAIError.networkUnavailable, peakLevel: 0.01))

        var machine = DictationStateMachine()
        XCTAssertNoThrow(try machine.transition(to: .transcribing, status: "Transcribing"))
        XCTAssertNoThrow(try machine.transition(to: .cancelled, status: "No speech detected"))
    }

    func testMaximumDurationStopsAndRemainsProcessable() {
        XCTAssertEqual(AudioRecorderService.maximumDuration, 480)
        XCTAssertEqual(
            AudioRecordingPolicy.decision(duration: 480, peakLevel: 0.05, reachedDurationLimit: true),
            .process(reachedDurationLimit: true)
        )
    }

    func testAutoFinishedRecordingKeepsElapsedDurationWhenRecorderTimeResets() {
        XCTAssertEqual(
            AudioRecordingTiming.finalizedDuration(
                recorderDuration: 0,
                elapsedDuration: 480
            ),
            480
        )
    }

    func testRecordingWarningPulseAcceleratesForFinalFifteenSeconds() {
        let maximum = AudioRecorderService.maximumDuration

        XCTAssertNil(RecordingWarningPulse.frequency(elapsed: maximum - 61, maximumDuration: maximum))
        XCTAssertEqual(RecordingWarningPulse.frequency(elapsed: maximum - 60, maximumDuration: maximum), 1)
        XCTAssertEqual(RecordingWarningPulse.frequency(elapsed: maximum - 16, maximumDuration: maximum), 1)
        XCTAssertEqual(RecordingWarningPulse.frequency(elapsed: maximum - 15, maximumDuration: maximum), 2)
        XCTAssertEqual(RecordingWarningPulse.frequency(elapsed: maximum, maximumDuration: maximum), 2)
    }

    func testShortcutValidationAllowsControlOptionModifierChord() {
        XCTAssertFalse(HotKeyShortcut(keyCode: 49, modifiers: 512).isValid)
        XCTAssertFalse(HotKeyShortcut(keyCode: 49, modifiers: 0).isValid)
        XCTAssertTrue(HotKeyShortcut(keyCode: 49, modifiers: 2048).isValid)
        XCTAssertTrue(HotKeyShortcut.default.isValid)
        XCTAssertTrue(HotKeyShortcut.default.isModifierOnly)
        XCTAssertEqual(HotKeyShortcut.default.displayName, "⌃⌥")
    }

    func testModifierChordTriggersOnlyOnInactiveToActiveEdge() {
        var tracker = ModifierChordEdgeTracker()
        let controlOption: UInt32 = 4096 | 2048

        XCTAssertFalse(tracker.update(currentModifiers: 4096, requiredModifiers: controlOption))
        XCTAssertTrue(tracker.update(currentModifiers: controlOption, requiredModifiers: controlOption))
        XCTAssertTrue(tracker.isActive)
        XCTAssertFalse(tracker.update(currentModifiers: controlOption, requiredModifiers: controlOption))
        XCTAssertFalse(tracker.update(currentModifiers: 2048, requiredModifiers: controlOption))
        XCTAssertFalse(tracker.isActive)
        XCTAssertTrue(tracker.update(currentModifiers: controlOption, requiredModifiers: controlOption))
    }

    func testStandaloneOptionSubmitsOnlyWhenReleased() {
        var tracker = OptionSubmitGestureTracker()
        tracker.setEnabled(true)

        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertTrue(tracker.update(currentModifiers: 0))
        XCTAssertFalse(tracker.update(currentModifiers: 0))
    }

    func testControlOptionGestureNeverBecomesStandaloneOptionSubmit() {
        var tracker = OptionSubmitGestureTracker()
        tracker.setEnabled(true)

        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertFalse(tracker.update(currentModifiers: 2048 | 4096))
        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertFalse(tracker.update(currentModifiers: 0))
    }

    func testEnablingDuringStartChordBlocksItsRelease() {
        var tracker = OptionSubmitGestureTracker()
        tracker.setEnabled(true, currentModifiers: 2048 | 4096)

        XCTAssertFalse(tracker.update(currentModifiers: 2048 | 4096))
        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertFalse(tracker.update(currentModifiers: 0))
        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertTrue(tracker.update(currentModifiers: 0))
    }

    func testEnablingAfterStartChordWasReleasedAcceptsFirstOptionPress() {
        var tracker = OptionSubmitGestureTracker()
        tracker.setEnabled(true, currentModifiers: 1)
        tracker.synchronizeNeutralState()

        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertTrue(tracker.update(currentModifiers: 0))
    }

    func testQueuedStartChordReleaseCannotSubmit() {
        var tracker = OptionSubmitGestureTracker()
        tracker.setEnabled(true, currentModifiers: 1)

        XCTAssertFalse(tracker.update(currentModifiers: 2048))
        XCTAssertFalse(tracker.update(currentModifiers: 0))
        tracker.synchronizeNeutralState()
        XCTAssertFalse(tracker.update(currentModifiers: 0))
    }
}
