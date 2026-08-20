import AppKit
import SwiftUI

struct ShortcutRecorderView: NSViewRepresentable {
    @Binding var shortcut: HotKeyShortcut

    func makeNSView(context: Context) -> ShortcutCaptureView {
        let view = ShortcutCaptureView()
        view.shortcut = shortcut
        view.onChange = { shortcut = $0 }
        return view
    }

    func updateNSView(_ view: ShortcutCaptureView, context: Context) {
        view.shortcut = shortcut
        view.needsDisplay = true
    }
}

final class ShortcutCaptureView: NSView {
    var shortcut: HotKeyShortcut = .default
    var onChange: ((HotKeyShortcut) -> Void)?
    private var capturing = false

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 28) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        capturing = true
        needsDisplay = true
    }

    override func resignFirstResponder() -> Bool {
        capturing = false
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= 4096 }
        if flags.contains(.option) { modifiers |= 2048 }
        if flags.contains(.shift) { modifiers |= 512 }
        if flags.contains(.command) { modifiers |= 256 }
        let candidate = HotKeyShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        guard candidate.isValid else {
            NSSound.beep()
            return
        }
        finishCapture(with: candidate)
    }

    override func flagsChanged(with event: NSEvent) {
        guard capturing else {
            super.flagsChanged(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.control), flags.contains(.option),
              !flags.contains(.shift), !flags.contains(.command) else { return }
        finishCapture(with: .default)
    }

    private func finishCapture(with candidate: HotKeyShortcut) {
        shortcut = candidate
        capturing = false
        onChange?(candidate)
        window?.makeFirstResponder(nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        (capturing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).stroke()
        let text = capturing ? "Press shortcut…" : shortcut.displayName
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
