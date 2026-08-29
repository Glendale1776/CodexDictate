import XCTest
@testable import CodexDictate

final class TargetSafetyTests: XCTestCase {
    private let original = CapturedTarget(
        processIdentifier: 42,
        bundleIdentifier: "com.microsoft.VSCode",
        applicationName: "Visual Studio Code",
        recordingStartedAt: Date(timeIntervalSince1970: 1)
    )

    func testMatchingVSCodeTargetCanPaste() {
        XCTAssertEqual(disposition(currentPID: 42), .paste)
    }

    func testChangedPIDInSameApplicationCanPaste() {
        XCTAssertEqual(disposition(currentPID: 43), .paste)
    }

    func testChangedApplicationCopies() {
        let current = CapturedTarget(
            processIdentifier: 43,
            bundleIdentifier: "com.apple.Safari",
            applicationName: "Safari",
            recordingStartedAt: Date()
        )
        XCTAssertEqual(
            TargetSafety.disposition(
                original: original,
                current: current,
                finalText: "Implement the parser.",
                automaticPaste: true,
                vscodeOnly: true,
                accessibilityGranted: true
            ),
            .copy(.targetChanged)
        )
    }

    func testNonVSCodeTargetCopiesByDefault() {
        let other = CapturedTarget(processIdentifier: 42, bundleIdentifier: "com.apple.TextEdit", applicationName: "TextEdit", recordingStartedAt: Date())
        let result = TargetSafety.disposition(
            original: other,
            current: other,
            finalText: "Hello",
            automaticPaste: true,
            vscodeOnly: true,
            accessibilityGranted: true
        )
        XCTAssertEqual(result, .copy(.targetNotAllowed))
    }

    func testMissingAccessibilityCopies() {
        XCTAssertEqual(disposition(currentPID: 42, accessibility: false), .copy(.accessibilityRequired))
    }

    func testBothPasteWorkflowsCanRestoreAnExactTarget() {
        XCTAssertTrue(
            TargetRecoveryPolicy.shouldRestoreExactTarget(
                disposition: .copy(.targetChanged)
            )
        )
        XCTAssertTrue(
            TargetRecoveryPolicy.shouldRestoreExactTarget(
                disposition: .paste
            )
        )
        XCTAssertFalse(
            TargetRecoveryPolicy.shouldRestoreExactTarget(
                disposition: .copy(.accessibilityRequired)
            )
        )
    }

    func testExactFocusRequiresCapturedEditorAsWellAsWindow() {
        XCTAssertTrue(ExactFocusPolicy.accepts(
            windowWasCaptured: true,
            windowMatches: true,
            editableElementWasCaptured: true,
            editableElementMatches: true
        ))
        XCTAssertFalse(ExactFocusPolicy.accepts(
            windowWasCaptured: true,
            windowMatches: true,
            editableElementWasCaptured: true,
            editableElementMatches: false
        ))
        XCTAssertTrue(ExactFocusPolicy.accepts(
            windowWasCaptured: true,
            windowMatches: true,
            editableElementWasCaptured: false,
            editableElementMatches: false
        ))
    }

    private func disposition(currentPID: pid_t, accessibility: Bool = true) -> PasteDisposition {
        let current = CapturedTarget(
            processIdentifier: currentPID,
            bundleIdentifier: original.bundleIdentifier,
            applicationName: original.applicationName,
            recordingStartedAt: Date()
        )
        return TargetSafety.disposition(
            original: original,
            current: current,
            finalText: "Implement the parser.",
            automaticPaste: true,
            vscodeOnly: true,
            accessibilityGranted: accessibility
        )
    }
}
