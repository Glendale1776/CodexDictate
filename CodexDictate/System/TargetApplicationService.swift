import AppKit
import ApplicationServices
import Carbon
import Foundation

@MainActor
protocol TargetApplicationProviding: AnyObject {
    func captureFrontmostTarget(at date: Date) -> CapturedTarget?
    func currentFrontmostTarget() -> CapturedTarget?
}

@MainActor
final class TargetApplicationService: TargetApplicationProviding {
    func captureFrontmostTarget(at date: Date = Date()) -> CapturedTarget? {
        makeTarget(date: date)
    }

    func currentFrontmostTarget() -> CapturedTarget? {
        makeTarget(date: Date())
    }

    private func makeTarget(date: Date) -> CapturedTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let textFrames = FocusedWindowLocator.focusedEditableTextFrames(for: app.processIdentifier)
        return CapturedTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: app.bundleIdentifier,
            applicationName: app.localizedName ?? "Unknown application",
            recordingStartedAt: date,
            windowFrame: FocusedWindowLocator.frame(for: app.processIdentifier),
            focusedElementFrame: textFrames?.element,
            focusedCaretFrame: textFrames?.caret
        )
    }
}

private enum FocusedWindowLocator {
    static func frame(for processIdentifier: pid_t) -> CGRect? {
        accessibilityFrame(for: processIdentifier) ?? windowServerFrame(for: processIdentifier)
    }

    static func focusedEditableTextFrames(
        for processIdentifier: pid_t
    ) -> (element: CGRect, caret: CGRect?)? {
        guard let element = focusedEditableElement(for: processIdentifier) else { return nil }

        guard let elementFrame = accessibilityElementFrame(element) else { return nil }
        let caret = CaretFrameResolver.frame(
            reportedCaret: caretFrame(for: element),
            in: elementFrame,
            rightToLeft: currentInputIsRightToLeft()
        )
        return (elementFrame, caret)
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
            var elementPID: pid_t = 0
            guard AXUIElementGetPid(element, &elementPID) == .success,
                  elementPID == processIdentifier,
                  isEditableTextElement(element) else { continue }
            return element
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
        guard let current, current.processIdentifier == original.processIdentifier else { return .copy(.targetChanged) }
        if vscodeOnly, !vscodeBundleIdentifiers.contains(original.bundleIdentifier ?? "") {
            return .copy(.targetNotAllowed)
        }
        guard accessibilityGranted else { return .copy(.accessibilityRequired) }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .copy(.automaticPasteDisabled)
        }
        return .paste
    }
}
