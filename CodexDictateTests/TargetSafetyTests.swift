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

    func testChangedPIDCopies() {
        XCTAssertEqual(disposition(currentPID: 43), .copy(.targetChanged))
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
