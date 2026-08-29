import Foundation
import XCTest
@testable import CodexDictate

@MainActor
final class KeychainLogicTests: XCTestCase {
    func testControllerUsesMockKeychainForSaveAndDelete() {
        let suite = "CodexDictateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = MockKeychain()
        let controller = makeController(settings: SettingsStore(defaults: defaults), keychain: keychain)

        XCTAssertNil(controller.saveAPIKey("  test-secret  "))
        XCTAssertEqual(keychain.value, "test-secret")
        XCTAssertTrue(controller.hasAPIKey)

        XCTAssertNil(controller.deleteAPIKey())
        XCTAssertNil(keychain.value)
        XCTAssertFalse(controller.hasAPIKey)
    }

    func testMenuBarVisibilityDefaultsOnAndPersists() {
        let suite = "CodexDictateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.showMenuBarIcon)

        var observedVisibility: Bool?
        settings.onMenuBarVisibilityChanged = { observedVisibility = $0 }
        settings.showMenuBarIcon = false

        XCTAssertEqual(observedVisibility, false)
        XCTAssertFalse(SettingsStore(defaults: defaults).showMenuBarIcon)
    }

    func testPreviousDefaultsMigrateToControlOption() throws {
        let suite = "CodexDictateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(try JSONEncoder().encode(HotKeyShortcut.legacyOptionSpaceDefault), forKey: "shortcut")
        XCTAssertEqual(SettingsStore(defaults: defaults).shortcut, .default)

        defaults.set(try JSONEncoder().encode(HotKeyShortcut.legacyPushToTalkDefault), forKey: "shortcut")
        XCTAssertEqual(SettingsStore(defaults: defaults).shortcut, .default)
        XCTAssertEqual(SettingsStore(defaults: defaults).shortcut.displayName, "⌃⌥")
        let persisted = try XCTUnwrap(defaults.data(forKey: "shortcut"))
        XCTAssertEqual(try JSONDecoder().decode(HotKeyShortcut.self, from: persisted), .default)
    }

    private func makeController(settings: SettingsStore, keychain: MockKeychain) -> DictationController {
        let board = ControllerPasteboard()
        return DictationController(
            settings: settings,
            permissions: PermissionService(),
            keychain: keychain,
            hotKey: ControllerHotKey(),
            audio: ControllerAudio(),
            targetService: ControllerTarget(),
            transcription: ControllerTranscription(),
            structuring: ControllerStructuring(),
            pasteService: PasteService(pasteboard: board, events: ControllerEvents())
        )
    }
}

private final class MockKeychain: KeychainStoring {
    var value: String?
    func containsKey() throws -> Bool { value != nil }
    func readKey() throws -> String? { value }
    func saveKey(_ key: String) throws { value = key }
    func deleteKey() throws { value = nil }
}

@MainActor
private final class ControllerHotKey: GlobalHotKeyServicing {
    var onPressed: (() -> Void)?
    var onSubmitPressed: (() -> Void)?
    func register(_ shortcut: HotKeyShortcut) throws {}
    func setOptionSubmitEnabled(_ enabled: Bool) throws {}
    func unregister() {}
}

@MainActor
private final class ControllerAudio: AudioRecorderServicing {
    var onMaximumDurationReached: (() -> Void)?
    var isRecording = false
    func start() throws { isRecording = true }
    func stop() throws -> RecordingArtifact { throw AudioRecorderError.notRecording }
    func cancel() { isRecording = false }
    func normalizedLevel() -> Float { 0 }
    func delete(_ url: URL) {}
    func cleanupAbandonedRecordings() {}
}

@MainActor
private final class ControllerTarget: TargetApplicationProviding {
    func captureFrontmostTarget(at date: Date) -> CapturedTarget? { nil }
    func currentFrontmostTarget() -> CapturedTarget? { nil }
    func activate(_ target: CapturedTarget) -> Bool { false }
    func isFocused(_ target: CapturedTarget) -> Bool { false }
}

private struct ControllerTranscription: TranscriptionServicing {
    func transcribe(audioURL: URL, keywords: [String], languages: [String], apiKey: String) async throws -> TranscriptionResult {
        throw OpenAIError.networkUnavailable
    }
}

private struct ControllerStructuring: TranscriptStructuringServicing {
    func structure(transcript: String, mode: StructuringMode, apiKey: String) async throws -> TranscriptStructuringResult {
        throw OpenAIError.networkUnavailable
    }
}

@MainActor
private final class ControllerPasteboard: PasteboardAccessing {
    var changeCount = 0
    func snapshot() -> PasteboardSnapshot { .init(items: []) }
    func replaceWithText(_ text: String) -> Int { changeCount += 1; return changeCount }
    func restore(_ snapshot: PasteboardSnapshot) -> Int { changeCount += 1; return changeCount }
}

@MainActor
private final class ControllerEvents: PasteEventGenerating {
    func postCommandV() throws {}
    func postReturn() throws {}
}
