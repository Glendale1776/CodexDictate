import ApplicationServices
import Foundation

@MainActor
protocol PasteEventGenerating: AnyObject {
    func postCommandV() throws
    func postReturn() throws
}

enum PasteEventError: Error {
    case eventSourceUnavailable
    case eventUnavailable
}

@MainActor
final class CGPasteEventGenerator: PasteEventGenerating {
    func postCommandV() throws {
        try postKey(9, flags: .maskCommand)
    }

    func postReturn() throws {
        try postKey(36, flags: [])
    }

    private func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else { throw PasteEventError.eventSourceUnavailable }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw PasteEventError.eventUnavailable
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@MainActor
final class PasteService {
    private let pasteboard: PasteboardAccessing
    private let events: PasteEventGenerating
    private let submitDelayNanoseconds: UInt64

    init(
        pasteboard: PasteboardAccessing = SystemPasteboard(),
        events: PasteEventGenerating = CGPasteEventGenerator(),
        submitDelayNanoseconds: UInt64 = 1_250_000_000
    ) {
        self.pasteboard = pasteboard
        self.events = events
        self.submitDelayNanoseconds = submitDelayNanoseconds
    }

    func copy(_ text: String) {
        _ = pasteboard.replaceWithText(text)
    }

    func paste(_ text: String) throws {
        let snapshot = pasteboard.snapshot()
        _ = pasteboard.replaceWithText(text)
        do {
            try events.postCommandV()
        } catch {
            _ = pasteboard.restore(snapshot)
            throw error
        }
        // Keep the result on the clipboard after posting Command-V. macOS does not
        // acknowledge whether an Electron editor accepted the synthetic event; an
        // automatic clipboard restore made a missed paste permanently unrecoverable.
        // Retaining the result lets the user press Command-V manually and is also the
        // safest fallback when focus changes during recognition.
    }

    func submitAfterPaste(
        prepareForSubmit: (@MainActor () async throws -> Void)? = nil
    ) async throws {
        try await Task<Never, Never>.sleep(nanoseconds: submitDelayNanoseconds)
        try await prepareForSubmit?()
        try events.postReturn()
    }

    @discardableResult
    func restoreIfUnchanged(_ snapshot: PasteboardSnapshot, insertedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == insertedChangeCount else { return false }
        _ = pasteboard.restore(snapshot)
        return true
    }
}
