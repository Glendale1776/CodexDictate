import AppKit
import AVFoundation
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionService
    @ObservedObject var launchAtLogin: LaunchAtLoginService

    @State private var apiKey = ""
    @State private var keyMessage: String?

    var body: some View {
        TabView {
            setupTab.tabItem { Label("Setup", systemImage: "checklist") }
            dictationTab.tabItem { Label("Dictation", systemImage: "waveform") }
            advancedTab.tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .padding(18)
        .frame(width: 560, height: 500)
        .onAppear {
            permissions.refresh()
            launchAtLogin.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // A privacy toggle is changed in System Settings while this app is
            // inactive. Refresh when the user returns so the setup UI does not
            // continue showing a stale "Required" state.
            permissions.refresh()
        }
    }

    private var setupTab: some View {
        Form {
            Section("OpenAI API key") {
                SecureField(controller.hasAPIKey ? "Stored in Keychain" : "sk-…", text: $apiKey)
                HStack {
                    Button("Save or Replace Key") {
                        keyMessage = controller.saveAPIKey(apiKey)
                        if keyMessage == nil { apiKey = "" }
                    }
                    Button("Delete Stored Key", role: .destructive) { keyMessage = controller.deleteAPIKey() }
                        .disabled(!controller.hasAPIKey)
                    Spacer()
                    Label(controller.hasAPIKey ? "Key stored" : "Key required", systemImage: controller.hasAPIKey ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(controller.hasAPIKey ? .green : .secondary)
                }
                if let keyMessage { Text(keyMessage).foregroundStyle(.red).font(.caption) }
            }
            Section("Permissions") {
                permissionRow(
                    title: "Microphone",
                    granted: permissions.microphoneStatus == .authorized,
                    actionTitle: permissions.microphoneStatus == .notDetermined ? "Request" : "Open Settings",
                    action: {
                        if permissions.microphoneStatus == .notDetermined {
                            Task { _ = await permissions.requestMicrophone() }
                        } else { permissions.openMicrophoneSettings() }
                    }
                )
                permissionRow(
                    title: "Accessibility",
                    granted: permissions.accessibilityGranted,
                    actionTitle: permissions.accessibilityGranted ? "Open Settings" : "Request",
                    action: {
                        if permissions.accessibilityGranted { permissions.openAccessibilitySettings() }
                        else { permissions.requestAccessibilityPrompt() }
                    }
                )
            }
            Section("Tap to dictate") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    ShortcutRecorderView(shortcut: $settings.shortcut).frame(width: 150, height: 28)
                }
                if let error = controller.hotKeyError { Text(error).foregroundStyle(.red).font(.caption) }
                Button(controller.state.phase == .recording ? "Stop Test Recording" : "Start Test Recording") {
                    controller.manualStartOrStop()
                }
                Text("Press Control + Option to start. Press it again to stop and paste, or tap Option by itself to stop, paste, and submit with Return.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var dictationTab: some View {
        Form {
            Toggle("Clean and format transcript", isOn: $settings.structureTranscript)
            Picker("Formatting style", selection: $settings.structuringMode) {
                ForEach(StructuringMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.disabled(!settings.structureTranscript)
            Toggle("Automatically paste result", isOn: $settings.automaticPaste)
            Toggle("Restrict automatic paste to VS Code", isOn: $settings.vscodeOnly)
                .disabled(!settings.automaticPaste)
            Section("Custom vocabulary — one term per line") {
                TextEditor(text: $settings.vocabulary).font(.system(.body, design: .monospaced)).frame(height: 130)
            }
            TextField("Expected language codes (optional, comma-separated)", text: $settings.expectedLanguages)
            Text("Leave languages empty for automatic detection. Invalid vocabulary characters are rejected before upload.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var advancedTab: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Text("When hidden, reopen CodexDictate from Applications to show this Settings window.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin.isEnabled },
                set: { launchAtLogin.setEnabled($0) }
            ))
            if let error = launchAtLogin.lastError { Text(error).foregroundStyle(.red).font(.caption) }
            Section("Privacy") {
                Text("Audio is kept only in a temporary file while transcription or retry is possible. Raw and processed text remain in memory only. Clipboard contents are restored only when unchanged after paste.")
                Text("CodexDictate sends audio and transcripts directly to OpenAI and includes no analytics or telemetry.")
            }
            Section("Safety") {
                Text("Automatic insertion uses only Command+V. CodexDictate never generates Enter, Return, or a submit command.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func permissionRow(title: String, granted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? .green : .primary)
            Spacer()
            Text(granted ? "Granted" : "Required").foregroundStyle(.secondary)
            Button(actionTitle, action: action)
        }
    }
}
