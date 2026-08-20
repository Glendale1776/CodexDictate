import Combine
import Foundation

struct HotKeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let modifierOnlyKeyCode = UInt32.max
    static let `default` = HotKeyShortcut(keyCode: modifierOnlyKeyCode, modifiers: 4096 | 2048)
    static let legacyOptionSpaceDefault = HotKeyShortcut(keyCode: 49, modifiers: 2048)
    static let legacyPushToTalkDefault = HotKeyShortcut(keyCode: 49, modifiers: 4096 | 2048)

    var isModifierOnly: Bool { keyCode == Self.modifierOnlyKeyCode }

    var isValid: Bool {
        let shift: UInt32 = 512
        let option: UInt32 = 2048
        let control: UInt32 = 4096
        let command: UInt32 = 256
        let meaningful = modifiers & (shift | option | control | command)
        if isModifierOnly {
            return meaningful == (control | option) && modifiers == meaningful
        }
        return meaningful & (option | control | command) != 0
    }

    var displayName: String {
        var result = ""
        if modifiers & 4096 != 0 { result += "⌃" }
        if modifiers & 2048 != 0 { result += "⌥" }
        if modifiers & 512 != 0 { result += "⇧" }
        if modifiers & 256 != 0 { result += "⌘" }
        if !isModifierOnly { result += Self.keyName(keyCode) }
        return result
    }

    private static func keyName(_ code: UInt32) -> String {
        switch code {
        case 49: "Space"
        case 36: "Return"
        case 53: "Escape"
        default: "Key (code)"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    private enum Key {
        static let structureTranscript = "structureTranscript"
        static let structuringMode = "structuringMode"
        static let automaticPaste = "automaticPaste"
        static let vscodeOnly = "vscodeOnly"
        static let vocabulary = "vocabulary"
        static let expectedLanguages = "expectedLanguages"
        static let shortcut = "shortcut"
        static let didLaunchBefore = "didLaunchBefore"
        static let showMenuBarIcon = "showMenuBarIcon"
    }

    private let defaults: UserDefaults
    var onShortcutChanged: ((HotKeyShortcut) -> Void)?
    var onMenuBarVisibilityChanged: ((Bool) -> Void)?

    @Published var structureTranscript: Bool { didSet { defaults.set(structureTranscript, forKey: Key.structureTranscript) } }
    @Published var structuringMode: StructuringMode { didSet { defaults.set(structuringMode.rawValue, forKey: Key.structuringMode) } }
    @Published var automaticPaste: Bool { didSet { defaults.set(automaticPaste, forKey: Key.automaticPaste) } }
    @Published var vscodeOnly: Bool { didSet { defaults.set(vscodeOnly, forKey: Key.vscodeOnly) } }
    @Published var vocabulary: String { didSet { defaults.set(vocabulary, forKey: Key.vocabulary) } }
    @Published var expectedLanguages: String { didSet { defaults.set(expectedLanguages, forKey: Key.expectedLanguages) } }
    @Published var showMenuBarIcon: Bool {
        didSet {
            defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon)
            onMenuBarVisibilityChanged?(showMenuBarIcon)
        }
    }
    @Published var shortcut: HotKeyShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: Key.shortcut) }
            onShortcutChanged?(shortcut)
        }
    }

    var isFirstLaunch: Bool { !defaults.bool(forKey: Key.didLaunchBefore) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        structureTranscript = defaults.object(forKey: Key.structureTranscript) as? Bool ?? true
        structuringMode = StructuringMode(rawValue: defaults.string(forKey: Key.structuringMode) ?? "") ?? .structured
        automaticPaste = defaults.object(forKey: Key.automaticPaste) as? Bool ?? true
        vscodeOnly = defaults.object(forKey: Key.vscodeOnly) as? Bool ?? true
        vocabulary = defaults.string(forKey: Key.vocabulary) ?? "OpenAI\nCodex\nVS Code"
        expectedLanguages = defaults.string(forKey: Key.expectedLanguages) ?? ""
        showMenuBarIcon = defaults.object(forKey: Key.showMenuBarIcon) as? Bool ?? true
        if let data = defaults.data(forKey: Key.shortcut),
           let decoded = try? JSONDecoder().decode(HotKeyShortcut.self, from: data),
           decoded.isValid {
            let isPreviousDefault = decoded == .legacyOptionSpaceDefault
                || decoded == .legacyPushToTalkDefault
            shortcut = isPreviousDefault ? .default : decoded
            if isPreviousDefault, let migrated = try? JSONEncoder().encode(HotKeyShortcut.default) {
                defaults.set(migrated, forKey: Key.shortcut)
            }
        } else {
            shortcut = .default
        }
    }

    func markLaunched() {
        defaults.set(true, forKey: Key.didLaunchBefore)
    }

    var vocabularyEntries: [String] {
        vocabulary.split(whereSeparator: \.isNewline).map(String.init)
    }

    var languageEntries: [String] {
        expectedLanguages
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
