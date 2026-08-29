import Foundation
import XCTest
@testable import CodexDictate

@MainActor
final class PasteServiceTests: XCTestCase {
    func testPasteboardSnapshotSerializationRoundTrip() throws {
        let snapshot = PasteboardSnapshot(items: [
            .init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("hello".utf8)),
                .init(type: "public.html", data: Data("<b>hello</b>".utf8))
            ])
        ])
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(PasteboardSnapshot.self, from: encoded), snapshot)
    }

    func testClipboardRestoresOnlyWhenChangeCountMatches() throws {
        let board = FakePasteboard()
        let events = FakePasteEvents()
        let service = PasteService(pasteboard: board, events: events)
        let original = board.snapshot()
        try service.paste("Final text")
        let insertedCount = board.changeCount
        XCTAssertTrue(service.restoreIfUnchanged(original, insertedChangeCount: insertedCount))
        XCTAssertEqual(board.restoredSnapshots, [original])

        _ = board.replaceWithText("User's newer clipboard")
        XCTAssertFalse(service.restoreIfUnchanged(original, insertedChangeCount: insertedCount))
        XCTAssertEqual(board.restoredSnapshots.count, 1)
    }

    func testPasteGeneratesCommandVWithoutReturn() throws {
        let board = FakePasteboard()
        let events = FakePasteEvents()
        let service = PasteService(pasteboard: board, events: events)
        try service.paste("Do not submit")
        XCTAssertEqual(events.commandVCount, 1)
        XCTAssertEqual(events.returnCount, 0)
    }

    func testSuccessfulPasteKeepsDictatedResultAvailableOnClipboard() async throws {
        let board = FakePasteboard()
        let service = PasteService(pasteboard: board, events: FakePasteEvents())

        try service.paste("Recoverable dictated result")
        try await Task<Never, Never>.sleep(nanoseconds: 2_100_000_000)

        XCTAssertEqual(board.currentText, "Recoverable dictated result")
        XCTAssertTrue(board.restoredSnapshots.isEmpty)
    }

    func testSubmitAfterPasteGeneratesReturn() async throws {
        let board = FakePasteboard()
        let events = FakePasteEvents()
        let service = PasteService(
            pasteboard: board,
            events: events,
            submitDelayNanoseconds: 0
        )

        try service.paste("Submit this")
        try await service.submitAfterPaste()

        XCTAssertEqual(events.commandVCount, 1)
        XCTAssertEqual(events.returnCount, 1)
    }

    func testSubmitPreparesTargetImmediatelyBeforeReturn() async throws {
        let events = FakePasteEvents()
        let service = PasteService(
            pasteboard: FakePasteboard(),
            events: events,
            submitDelayNanoseconds: 0
        )
        var prepared = false

        try await service.submitAfterPaste {
            XCTAssertEqual(events.returnCount, 0)
            prepared = true
        }

        XCTAssertTrue(prepared)
        XCTAssertEqual(events.returnCount, 1)
    }

    func testFailedTargetPreparationPreventsReturn() async {
        let events = FakePasteEvents()
        let service = PasteService(
            pasteboard: FakePasteboard(),
            events: events,
            submitDelayNanoseconds: 0
        )

        do {
            try await service.submitAfterPaste {
                throw DictationFailure.targetChanged
            }
            XCTFail("Expected target preparation to fail")
        } catch {
            XCTAssertEqual(error as? DictationFailure, .targetChanged)
        }

        XCTAssertEqual(events.returnCount, 0)
    }
}

@MainActor
private final class FakePasteboard: PasteboardAccessing {
    private(set) var changeCount = 10
    private(set) var currentText = "Original"
    private(set) var restoredSnapshots: [PasteboardSnapshot] = []

    func snapshot() -> PasteboardSnapshot {
        PasteboardSnapshot(items: [.init(representations: [.init(type: "public.utf8-plain-text", data: Data(currentText.utf8))])])
    }

    func replaceWithText(_ text: String) -> Int {
        currentText = text
        changeCount += 1
        return changeCount
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Int {
        restoredSnapshots.append(snapshot)
        changeCount += 1
        return changeCount
    }
}

@MainActor
private final class FakePasteEvents: PasteEventGenerating {
    private(set) var commandVCount = 0
    private(set) var returnCount = 0
    func postCommandV() throws { commandVCount += 1 }
    func postReturn() throws { returnCount += 1 }
}
