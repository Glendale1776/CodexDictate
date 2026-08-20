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
    private var restorationTask: Task<Void, Never>?

    init(
        pasteboard: PasteboardAccessing = SystemPasteboard(),
        events: PasteEventGenerating = CGPasteEventGenerator(),
        submitDelayNanoseconds: UInt64 = 600_000_000
    ) {
        self.pasteboard = pasteboard
        self.events = events
        self.submitDelayNanoseconds = submitDelayNanoseconds
    }

    func copy(_ text: String) {
        restorationTask?.cancel()
        _ = pasteboard.replaceWithText(text)
    }

    func paste(_ text: String) throws {
        restorationTask?.cancel()
        let snapshot = pasteboard.snapshot()
        let insertedChangeCount = pasteboard.replaceWithText(text)
        do {
            try events.postCommandV()
        } catch {
            _ = pasteboard.restore(snapshot)
            throw error
        }
        restorationTask = Task { @MainActor [weak self] in
            // Keep the dictated text available long enough for a busy Electron
            // renderer to handle Command-V before restoring the user's clipboard.
            try? await Task<Never, Never>.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            _ = self?.restoreIfUnchanged(snapshot, insertedChangeCount: insertedChangeCount)
        }
    }

    func submitAfterPaste() async throws {
        try await Task<Never, Never>.sleep(nanoseconds: submitDelayNanoseconds)
        try events.postReturn()
    }

    @discardableResult
    func restoreIfUnchanged(_ snapshot: PasteboardSnapshot, insertedChangeCount: Int) -> Bool {
        guard pasteboard.changeCount == insertedChangeCount else { return false }
        _ = pasteboard.restore(snapshot)
        return true
    }
}
