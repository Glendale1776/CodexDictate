import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
protocol TargetApplicationProviding: AnyObject {
    func captureFrontmostTarget(at date: Date) -> CapturedTarget?
    func currentFrontmostTarget() -> CapturedTarget?
    func activate(_ target: CapturedTarget) -> Bool
    func isFocused(_ target: CapturedTarget) -> Bool
}

enum ExactFocusPolicy {
    static func accepts(
        windowWasCaptured: Bool,
        windowMatches: Bool,
        editableElementWasCaptured: Bool,
        editableElementMatches: Bool
    ) -> Bool {
        (!windowWasCaptured || windowMatches)
            && (!editableElementWasCaptured || editableElementMatches)
    }
}

@MainActor
final class TargetApplicationService: TargetApplicationProviding {
    private struct FocusSnapshot {
        let window: AXUIElement?
        let editableElement: AXUIElement?
    }

    private var focusSnapshots: [UUID: FocusSnapshot] = [:]

    func captureFrontmostTarget(at date: Date = Date()) -> CapturedTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let snapshotIdentifier = UUID()
        let focus = FocusedWindowLocator.captureFocus(for: app.processIdentifier)
        // Only one recording can be active. Avoid retaining stale accessibility
        // objects after their delivery attempt is no longer relevant.
        focusSnapshots.removeAll(keepingCapacity: true)
        focusSnapshots[snapshotIdentifier] = FocusSnapshot(
            window: focus.window,
            editableElement: focus.editableElement
        )
        return makeTarget(
            app: app,
            date: date,
            focusSnapshotIdentifier: snapshotIdentifier
        )
    }

    func currentFrontmostTarget() -> CapturedTarget? {
        makeTarget(date: Date())
    }

    func activate(_ target: CapturedTarget) -> Bool {
        let exactApplication = NSRunningApplication(processIdentifier: target.processIdentifier)
        let application: NSRunningApplication?
        if let exactApplication,
           exactApplication.bundleIdentifier == target.bundleIdentifier {
            application = exactApplication
        } else if let bundleIdentifier = target.bundleIdentifier {
            application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first
        } else {
            application = nil
        }

        guard let application else { return false }
        let applicationElement = AXUIElementCreateApplication(application.processIdentifier)
        let activated = application.activate(options: [])
        _ = AXUIElementSetAttributeValue(
            applicationElement,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )

        guard let identifier = target.focusSnapshotIdentifier,
              let snapshot = focusSnapshots[identifier] else {
            return activated
        }

        var restoredExactWindow = false
        if let window = snapshot.window {
            restoredExactWindow = AXUIElementPerformAction(
                window,
                kAXRaiseAction as CFString
            ) == .success
            _ = AXUIElementSetAttributeValue(
                window,
                kAXMainAttribute as CFString,
                kCFBooleanTrue
            )
            _ = AXUIElementSetAttributeValue(
                window,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        if let editableElement = snapshot.editableElement {
            _ = AXUIElementSetAttributeValue(
                editableElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
        }
        return restoredExactWindow || activated
    }

    func isFocused(_ target: CapturedTarget) -> Bool {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == target.processIdentifier
                || (target.bundleIdentifier != nil
                    && frontmost.bundleIdentifier == target.bundleIdentifier) else {
            return false
        }
        guard let identifier = target.focusSnapshotIdentifier,
              let snapshot = focusSnapshots[identifier] else {
            return true
        }
        let windowMatches: Bool
        if let capturedWindow = snapshot.window,
           let focusedWindow = FocusedWindowLocator.focusedWindow(for: frontmost.processIdentifier) {
            windowMatches = CFEqual(capturedWindow, focusedWindow)
        } else {
            windowMatches = snapshot.window == nil
        }
        let editableElementMatches: Bool
        if let capturedEditableElement = snapshot.editableElement {
            editableElementMatches = FocusedWindowLocator.focusedEditableElement(
                equals: capturedEditableElement,
                for: frontmost.processIdentifier
            )
        } else {
            editableElementMatches = true
        }
        return ExactFocusPolicy.accepts(
            windowWasCaptured: snapshot.window != nil,
            windowMatches: windowMatches,
            editableElementWasCaptured: snapshot.editableElement != nil,
            editableElementMatches: editableElementMatches
        )
    }

    private func makeTarget(date: Date) -> CapturedTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return makeTarget(app: app, date: date, focusSnapshotIdentifier: nil)
    }

    private func makeTarget(
        app: NSRunningApplication,
        date: Date,
        focusSnapshotIdentifier: UUID?
    ) -> CapturedTarget {
        let textFrames = FocusedWindowLocator.focusedEditableTextFrames(for: app.processIdentifier)
        let focusSnapshot = focusSnapshotIdentifier.flatMap { focusSnapshots[$0] }
        return CapturedTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName ?? "Unknown application",
            recordingStartedAt: date,
            windowFrame: FocusedWindowLocator.frame(for: app.processIdentifier),
            focusedElementFrame: textFrames?.element,
            focusedCaretFrame: textFrames?.caret,
            focusSnapshotIdentifier: focusSnapshotIdentifier,
            capturedWindowReference: focusSnapshot?.window != nil,
            capturedEditableElementReference: focusSnapshot?.editableElement != nil
        )
    }
}

private enum FocusedWindowLocator {
    static func focusedEditableElement(
        equals expected: AXUIElement,
        for processIdentifier: pid_t
    ) -> Bool {
        guard let current = focusedEditableElement(for: processIdentifier) else { return false }
        return CFEqual(expected, current)
    }

    static func focusedWindow(for processIdentifier: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success, let value else { return nil }
        return (value as! AXUIElement)
    }

    static func captureFocus(
        for processIdentifier: pid_t
    ) -> (window: AXUIElement?, editableElement: AXUIElement?) {
        (
            focusedWindow(for: processIdentifier),
            focusedEditableElement(for: processIdentifier)
        )
    }

    static func frame(for processIdentifier: pid_t) -> CGRect? {
        accessibilityFrame(for: processIdentifier) ?? windowServerFrame(for: processIdentifier)
    }

    static func focusedEditableTextFrames(
        for processIdentifier: pid_t
    ) -> (element: CGRect, caret: CGRect?)? {
        guard let element = focusedEditableElement(for: processIdentifier) else { return nil }

        guard let elementFrame = accessibilityElementFrame(element)
            ?? nearestDescendantFrame(of: element) else { return nil }
        let caret = CaretFrameResolver.frame(
            reportedCaret: caretFrame(for: element),
            in: elementFrame,
            rightToLeft: currentInputIsRightToLeft()
        )
        return (elementFrame, caret)
    }

    private static func nearestDescendantFrame(
        of element: AXUIElement,
        maximumDepth: Int = 4,
        maximumElements: Int = 64
    ) -> CGRect? {
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var index = 0

        while index < queue.count, index < maximumElements {
            let item = queue[index]
            index += 1
            guard item.depth < maximumDepth else { continue }

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                item.element,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
            let children = childrenValue as? [AXUIElement] else { continue }

            for child in children {
                if let frame = accessibilityElementFrame(child) { return frame }
                queue.append((child, item.depth + 1))
            }
        }
        return nil
    }

    private static func focusedEditableElement(for processIdentifier: pid_t) -> AXUIElement? {
        let roots = [
            AXUIElementCreateSystemWide(),
            AXUIElementCreateApplication(processIdentifier)
        ]
        for root in roots {
            var focusedElementValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                root,
                kAXFocusedUIElementAttribute as CFString,
                &focusedElementValue
            ) == .success, let focusedElementValue else { continue }

            let element = focusedElementValue as! AXUIElement
            // Electron exposes a focused editor through a renderer-helper process,
            // while NSWorkspace identifies the frontmost application by its main
            // process. Requiring those PIDs to match rejects the real VS Code editor.
            // The system-wide focused element and the app's own focused element are
            // already scoped to the active application, so resolve either directly
            // or through its Chromium accessibility ancestors.
            if let editable = editableElementInParentChain(startingAt: element) {
                return editable
            }
            if let editable = editableDescendant(of: element) {
                return editable
            }
        }
        return nil
    }

    private static func editableDescendant(
        of element: AXUIElement,
        maximumDepth: Int = 12,
        maximumElements: Int = 512
    ) -> AXUIElement? {
        var stack: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var inspected = 0

        while let item = stack.popLast(), inspected < maximumElements {
            inspected += 1
            if item.depth > 0, isEditableTextElement(item.element) {
                return item.element
            }
            guard item.depth < maximumDepth else { continue }

            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                item.element,
                kAXChildrenAttribute as CFString,
                &childrenValue
            ) == .success,
            let children = childrenValue as? [AXUIElement] else { continue }

            // The Codex composer is the trailing branch of its webview. A LIFO
            // traversal reaches it before walking a potentially long chat transcript.
            for child in children { stack.append((child, item.depth + 1)) }
        }
        return nil
    }

    private static func editableElementInParentChain(
        startingAt element: AXUIElement,
        maximumDepth: Int = 8
    ) -> AXUIElement? {
        var current: AXUIElement? = element
        for _ in 0...maximumDepth {
            guard let candidate = current else { return nil }
            if isEditableTextElement(candidate) { return candidate }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                candidate,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success, let parentValue else { return nil }
            current = (parentValue as! AXUIElement)
        }
        return nil
    }

    private static func caretFrame(for element: AXUIElement) -> CGRect? {
        var selectedRangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success, let selectedRangeValue else { return nil }

        let rangeValue = selectedRangeValue as! AXValue
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange),
              selectedRange.location >= 0,
              selectedRange.length == 0 else { return nil }

        // Chromium-based editors can return a stale bounds-for-range rectangle for an
        // empty contenteditable element. It often points near the bottom of the webview
        // rather than at the placeholder's first line.
        let knownTextLength = effectiveTextLength(of: element)
        if knownTextLength == 0 { return nil }

        if let bounds = quartzBounds(for: rangeValue, in: element), bounds.height > 0 {
            return appKitFrame(fromQuartzFrame: bounds)
        }

        guard let textLength = knownTextLength, textLength > 0 else { return nil }
        let rightToLeft = currentInputIsRightToLeft()
        let neighborRange: CFRange
        let caretX: (CGRect) -> CGFloat
        if selectedRange.location < textLength {
            neighborRange = CFRange(location: selectedRange.location, length: 1)
            caretX = { rightToLeft ? $0.maxX : $0.minX }
        } else {
            neighborRange = CFRange(location: textLength - 1, length: 1)
            caretX = { rightToLeft ? $0.minX : $0.maxX }
        }

        var mutableRange = neighborRange
        guard let neighborRangeValue = AXValueCreate(.cfRange, &mutableRange),
              let neighborBounds = quartzBounds(for: neighborRangeValue, in: element),
              neighborBounds.height > 0 else { return nil }
        let quartzCaret = CGRect(
            x: caretX(neighborBounds),
            y: neighborBounds.minY,
            width: 1,
            height: neighborBounds.height
        )
        return appKitFrame(fromQuartzFrame: quartzCaret)
    }

    private static func quartzBounds(for rangeValue: AXValue, in element: AXUIElement) -> CGRect? {
        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success, let boundsValue else { return nil }

        let axBounds = boundsValue as! AXValue
        var quartzBounds = CGRect.zero
        guard AXValueGetValue(axBounds, .cgRect, &quartzBounds) else { return nil }
        return quartzBounds
    }

    private static func effectiveTextLength(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success, let text = value as? String else { return nil }

        var placeholderValue: CFTypeRef?
        let placeholder = AXUIElementCopyAttributeValue(
            element,
            kAXPlaceholderValueAttribute as CFString,
            &placeholderValue
        ) == .success ? placeholderValue as? String : nil

        return EditableTextContent.effectiveLength(value: text, placeholder: placeholder)
    }

    private static func currentInputIsRightToLeft() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return false
        }
        let languages = Unmanaged<CFArray>.fromOpaque(pointer).takeUnretainedValue() as? [String] ?? []
        return languages.contains {
            Locale.Language(identifier: $0).characterDirection == .rightToLeft
        }
    }

    private static func accessibilityFrame(for processIdentifier: pid_t) -> CGRect? {
        let application = AXUIElementCreateApplication(processIdentifier)
        var focusedWindowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success, let focusedWindowValue else { return nil }

        return accessibilityElementFrame(focusedWindowValue as! AXUIElement)
    }

    private static func isEditableTextElement(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success, let role = roleValue as? String else { return false }

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if textRoles.contains(role) { return true }

        var selectedRangeValue: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeValue
        ) == .success && selectedRangeValue != nil
    }

    private static func accessibilityElementFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else { return nil }

        let axPosition = positionValue as! AXValue
        let axSize = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetValue(axSize, .cgSize, &size),
              size.width > 0,
              size.height > 0 else { return nil }

        return appKitFrame(fromQuartzFrame: CGRect(origin: position, size: size))
    }

    private static func windowServerFrame(for processIdentifier: pid_t) -> CGRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let quartzFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  quartzFrame.width > 0,
                  quartzFrame.height > 0 else { continue }
            return appKitFrame(fromQuartzFrame: quartzFrame)
        }
        return nil
    }

    private static func appKitFrame(fromQuartzFrame frame: CGRect) -> CGRect {
        let primaryScreenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return CGRect(
            x: frame.minX,
            y: primaryScreenTop - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

enum CaretFallbackPlacement {
    static func frame(in elementFrame: CGRect, rightToLeft: Bool) -> CGRect {
        let horizontalInset = min(2, elementFrame.width / 4)
        let caretHeight = min(20, max(1, elementFrame.height - 8))
        let caretY = elementFrame.height > 48
            ? elementFrame.maxY - caretHeight - 8
            : elementFrame.midY - caretHeight / 2
        return CGRect(
            x: rightToLeft ? elementFrame.maxX - horizontalInset : elementFrame.minX + horizontalInset,
            y: caretY,
            width: 1,
            height: caretHeight
        )
    }
}

enum CaretFrameResolver {
    static func frame(
        reportedCaret: CGRect?,
        in elementFrame: CGRect,
        rightToLeft: Bool
    ) -> CGRect {
        if let reportedCaret, isUsable(reportedCaret, within: elementFrame) {
            return reportedCaret
        }
        return CaretFallbackPlacement.frame(in: elementFrame, rightToLeft: rightToLeft)
    }

    private static func isUsable(_ caret: CGRect, within element: CGRect) -> Bool {
        guard !caret.isNull,
              caret.minX.isFinite,
              caret.minY.isFinite,
              caret.width.isFinite,
              caret.height.isFinite,
              caret.width >= 0,
              caret.width <= 8,
              caret.height > 0,
              caret.height <= element.height + 4 else { return false }

        return caret.midX >= element.minX - 2
            && caret.midX <= element.maxX + 2
            && caret.midY >= element.minY - 2
            && caret.midY <= element.maxY + 2
    }
}

enum EditableTextContent {
    static func effectiveLength(value: String, placeholder: String?) -> Int {
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedValue.isEmpty else { return 0 }

        if let placeholder {
            let normalizedPlaceholder = placeholder.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedPlaceholder.isEmpty, normalizedValue == normalizedPlaceholder {
                return 0
            }
        }
        return value.utf16.count
    }
}

enum TargetSafety {
    static let vscodeBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders"
    ]

    static func disposition(
        original: CapturedTarget,
        current: CapturedTarget?,
        finalText: String,
        automaticPaste: Bool,
        vscodeOnly: Bool,
        accessibilityGranted: Bool
    ) -> PasteDisposition {
        guard automaticPaste else { return .copy(.automaticPasteDisabled) }
        guard let current, isSameApplication(original, current) else { return .copy(.targetChanged) }
        if vscodeOnly, !vscodeBundleIdentifiers.contains(original.bundleIdentifier ?? "") {
            return .copy(.targetNotAllowed)
        }
        guard accessibilityGranted else { return .copy(.accessibilityRequired) }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .copy(.automaticPasteDisabled)
        }
        return .paste
    }

    static func isSameApplication(_ lhs: CapturedTarget, _ rhs: CapturedTarget) -> Bool {
        if lhs.processIdentifier == rhs.processIdentifier { return true }
        guard let lhsBundle = lhs.bundleIdentifier,
              let rhsBundle = rhs.bundleIdentifier else { return false }
        return lhsBundle == rhsBundle
    }
}

enum TargetRecoveryPolicy {
    static func shouldRestoreExactTarget(disposition: PasteDisposition) -> Bool {
        disposition == .paste || disposition == .copy(.targetChanged)
    }
}
