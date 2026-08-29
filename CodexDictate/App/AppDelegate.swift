import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var settingsWindow: NSWindow?
    private var hudController: HUDController?
    private var cancellables = Set<AnyCancellable>()

    private var controller: DictationController!
    private var settings: SettingsStore!
    private var permissions: PermissionService!
    private var launchAtLogin: LaunchAtLoginService!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosted unit tests must not register a real global hotkey, read the user's
        // Keychain, clean live retry files, or open first-run UI.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        NSApp.setActivationPolicy(.accessory)
        settings = SettingsStore()
        permissions = PermissionService()
        launchAtLogin = LaunchAtLoginService()
        let diagnostics = DiagnosticStore()
        let client = OpenAIClient(diagnostics: diagnostics)
        controller = DictationController(
            settings: settings,
            permissions: permissions,
            keychain: KeychainService(),
            hotKey: GlobalHotKeyService(),
            audio: AudioRecorderService(),
            targetService: TargetApplicationService(),
            transcription: TranscriptionService(client: client),
            structuring: TranscriptStructuringService(client: client, diagnostics: diagnostics),
            pasteService: PasteService(),
            diagnostics: diagnostics
        )
        controller.start()
        hudController = HUDController(controller: controller)
        configureStatusItem()
        controller.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }.store(in: &cancellables)

        if controller.needsFirstRunSetup {
            Task { @MainActor [weak self] in
                try? await Task<Never, Never>.sleep(nanoseconds: 350_000_000)
                self?.showSettings(nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.terminate()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "CodexDictate")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.isVisible = settings.showMenuBarIcon
        settings.onMenuBarVisibilityChanged = { [weak self] isVisible in
            self?.statusItem.isVisible = isVisible
        }
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        permissions.refresh()
        launchAtLogin.refresh()
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let status = NSMenuItem(title: controller.state.status, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let recordTitle = controller.state.phase == .recording ? "Stop Recording" : "Start Recording"
        let record = NSMenuItem(title: recordTitle, action: #selector(startOrStop), keyEquivalent: "")
        record.target = self
        menu.addItem(record)

        let copyProcessed = NSMenuItem(title: "Copy Last Processed Result", action: #selector(copyLastProcessed), keyEquivalent: "")
        copyProcessed.target = self
        copyProcessed.isEnabled = controller.lastProcessedResult != nil
        menu.addItem(copyProcessed)

        let copyRaw = NSMenuItem(title: "Copy Last Raw Transcript", action: #selector(copyLastRaw), keyEquivalent: "")
        copyRaw.target = self
        copyRaw.isEnabled = controller.lastRawTranscript != nil
        menu.addItem(copyRaw)

        let retry = NSMenuItem(title: "Retry Last Failed Recording", action: #selector(retryLast), keyEquivalent: "")
        retry.target = self
        retry.isEnabled = controller.canRetryFailedRecording
        menu.addItem(retry)

        let diagnostics = NSMenuItem(
            title: "Copy Recent Diagnostics (\(controller.diagnosticSessionCount))",
            action: #selector(copyRecentDiagnostics),
            keyEquivalent: ""
        )
        diagnostics.target = self
        diagnostics.isEnabled = controller.diagnosticSessionCount > 0
        menu.addItem(diagnostics)
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = launchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit CodexDictate", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let symbol: String
        switch controller.state.phase {
        case .recording: symbol = "waveform.circle.fill"
        case .failed: symbol = "exclamationmark.triangle"
        case .idle: symbol = "waveform"
        default: symbol = "ellipsis.circle"
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.state.status)
        rebuildMenu()
    }

    @objc private func startOrStop() { controller.manualStartOrStop() }
    @objc private func copyLastProcessed() { controller.copyLastProcessed() }
    @objc private func copyLastRaw() { controller.copyLastRaw() }
    @objc private func retryLast() { controller.retryLastFailedRecording() }
    @objc private func copyRecentDiagnostics() { controller.copyRecentDiagnostics() }

    @objc private func toggleLaunchAtLogin() {
        launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        rebuildMenu()
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let view = SettingsView(controller: controller, settings: settings, permissions: permissions, launchAtLogin: launchAtLogin)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "CodexDictate Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.setContentSize(NSSize(width: 560, height: 500))
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("CodexDictateSettings")
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return true
    }

    @objc private func quitApplication() { NSApp.terminate(nil) }
}
