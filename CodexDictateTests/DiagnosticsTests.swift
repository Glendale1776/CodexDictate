import Foundation
import XCTest
@testable import CodexDictate

final class DiagnosticsTests: XCTestCase {
    func testStoreRetainsOnlyFiveMostRecentSessions() async {
        let store = DiagnosticStore()
        let base = Date(timeIntervalSince1970: 1_000)

        for offset in 0..<7 {
            _ = await store.beginSession(
                context: context(applicationName: "Target \(offset)"),
                at: base.addingTimeInterval(TimeInterval(offset))
            )
        }

        let sessions = await store.snapshot()
        XCTAssertEqual(sessions.count, 5)
        XCTAssertEqual(sessions.map(\.context.targetApplicationName), [
            "Target 2", "Target 3", "Target 4", "Target 5", "Target 6"
        ])
    }

    func testExportContainsTypedMetadataButNoSensitiveContent() async throws {
        let store = DiagnosticStore()
        let sessionID = await store.beginSession(context: context(applicationName: "Visual Studio Code"))
        await store.record(DiagnosticEvent(
            name: .httpResponse,
            stage: .transcription,
            outcome: .success,
            durationMilliseconds: 842,
            attempt: 1,
            httpStatus: 200,
            byteCount: 123
        ), sessionID: sessionID)
        await store.finish(sessionID: sessionID, outcome: .paste)

        let export = await store.exportJSON(now: Date(timeIntervalSince1970: 2_000))
        let data = try XCTUnwrap(export.data(using: .utf8))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DiagnosticExportEnvelope.self, from: data)

        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.sessions[0].events.first?.httpStatus, 200)
        XCTAssertEqual(decoded.sessions[0].finalOutcome, .paste)
        XCTAssertTrue(decoded.privacy.persistence.contains("Memory only"))
        XCTAssertFalse(export.contains("sk-secret"))
        XCTAssertFalse(export.contains("This is the dictated prompt"))
    }

    func testErrorSanitizerNeverIncludesDynamicMessageText() {
        let secret = "This is the dictated prompt and sk-secret"
        let code = DiagnosticErrorSanitizer.code(for: DictationFailure.message(secret))
        XCTAssertEqual(code, "dictation.message")
        XCTAssertFalse(code.contains(secret))
    }

    func testNewStoreStartsEmptyBecauseDiagnosticsAreMemoryOnly() async {
        let first = DiagnosticStore()
        _ = await first.beginSession(context: context(applicationName: "VS Code"))
        let firstCount = await first.sessionCount()
        XCTAssertEqual(firstCount, 1)

        let relaunchedStore = DiagnosticStore()
        let relaunchedCount = await relaunchedStore.sessionCount()
        XCTAssertEqual(relaunchedCount, 0)
    }

    private func context(applicationName: String) -> DiagnosticSessionContext {
        DiagnosticSessionContext(
            targetBundleIdentifier: "com.microsoft.VSCode",
            targetApplicationName: applicationName,
            targetProcessIdentifier: 42,
            capturedWindow: true,
            capturedEditableElement: true,
            capturedCaret: true,
            capturedExactFocus: true,
            automaticPaste: true,
            restrictPasteToVSCode: true,
            formattingEnabled: true,
            formattingMode: StructuringMode.structured.rawValue,
            microphoneGranted: true,
            accessibilityGranted: true
        )
    }
}
