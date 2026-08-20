import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDController {
    private static let panelSize = NSSize(width: 90, height: 1.25)

    private let panel: NSPanel
    private unowned let controller: DictationController
    private var cancellable: AnyCancellable?

    init(controller: DictationController) {
        self.controller = controller
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = NSHostingView(rootView: HUDView(controller: controller))

        cancellable = controller.$state.sink { [weak self] state in
            self?.update(for: state.phase)
        }
    }

    private func update(for phase: DictationPhase) {
        if phase == .idle || phase == .completed {
            panel.orderOut(nil)
            return
        }
        positionPanel(
            below: controller.indicatorFocusedElementFrame,
            at: controller.indicatorFocusedCaretFrame,
            near: controller.indicatorTargetWindowFrame
        )
        panel.orderFrontRegardless()
    }

    private func positionPanel(
        below focusedElementFrame: CGRect?,
        at focusedCaretFrame: CGRect?,
        near targetWindowFrame: CGRect?
    ) {
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        guard let origin = HUDPlacement.origin(
            panelSize: panel.frame.size,
            focusedElementFrame: focusedElementFrame,
            focusedCaretFrame: focusedCaretFrame,
            targetWindowFrame: targetWindowFrame,
            screenFrames: screenFrames,
            fallbackPoint: NSEvent.mouseLocation
        ) else { return }
        panel.setFrameOrigin(origin)
    }
}

private struct HUDView: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        Capsule(style: .continuous)
            .fill(indicatorColor)
            .opacity(indicatorOpacity)
            .frame(width: 90, height: 1.25)
            .shadow(color: indicatorColor.opacity(0.4), radius: 0.75)
            .animation(.easeOut(duration: 0.16), value: controller.state.phase)
            .animation(.linear(duration: 0.08), value: controller.audioLevel)
    }

    private var indicatorColor: Color {
        switch controller.state.phase {
        case .recording: .red
        default: .orange
        }
    }

    private var indicatorOpacity: Double {
        guard controller.state.phase == .recording else { return 0.9 }
        if let warningOpacity = RecordingWarningPulse.opacity(
            elapsed: controller.recordingDuration,
            maximumDuration: AudioRecorderService.maximumDuration
        ) {
            return warningOpacity
        }
        return 0.65 + (0.35 * Double(controller.audioLevel))
    }
}

enum RecordingWarningPulse {
    static let warningDuration: TimeInterval = 60
    static let urgentDuration: TimeInterval = 15

    static func frequency(
        elapsed: TimeInterval,
        maximumDuration: TimeInterval
    ) -> Double? {
        let remaining = maximumDuration - elapsed
        guard remaining <= warningDuration else { return nil }
        return remaining <= urgentDuration ? 2 : 1
    }

    static func opacity(
        elapsed: TimeInterval,
        maximumDuration: TimeInterval
    ) -> Double? {
        guard let frequency = frequency(
            elapsed: elapsed,
            maximumDuration: maximumDuration
        ) else { return nil }
        let wave = (cos(elapsed * frequency * 2 * .pi) + 1) / 2
        return 0.2 + (0.8 * wave)
    }
}

enum HUDPlacement {
    private static let caretGap: CGFloat = 2
    private static let fieldInset: CGFloat = 2
    private static let windowBottomInset: CGFloat = 14
    private static let screenEdgeInset: CGFloat = 10

    static func origin(
        panelSize: CGSize,
        focusedElementFrame: CGRect?,
        focusedCaretFrame: CGRect?,
        targetWindowFrame: CGRect?,
        screenFrames: [CGRect],
        fallbackPoint: CGPoint
    ) -> CGPoint? {
        guard !screenFrames.isEmpty else { return nil }

        let screen = bestScreen(
            for: usable(focusedElementFrame) ?? usable(targetWindowFrame),
            screenFrames: screenFrames,
            fallbackPoint: fallbackPoint
        )

        let desiredX: CGFloat
        let desiredY: CGFloat
        if let focusedElementFrame = usable(focusedElementFrame) {
            if let caretFrame = usableCaret(focusedCaretFrame, within: focusedElementFrame) {
                let fieldMinX = focusedElementFrame.minX + fieldInset
                let fieldMaxX = max(
                    fieldMinX,
                    focusedElementFrame.maxX - panelSize.width - fieldInset
                )
                let caretX = caretFrame.midX
                let caretLeadingX = caretX + panelSize.width <= focusedElementFrame.maxX - fieldInset
                    ? caretX
                    : caretX - panelSize.width
                desiredX = min(max(caretLeadingX, fieldMinX), fieldMaxX)

                let fieldMinY = focusedElementFrame.minY + fieldInset
                let fieldMaxY = max(
                    fieldMinY,
                    focusedElementFrame.maxY - panelSize.height - fieldInset
                )
                let caretY = caretFrame.minY - panelSize.height - caretGap
                desiredY = min(max(caretY, fieldMinY), fieldMaxY)
            } else {
                desiredX = focusedElementFrame.midX - panelSize.width / 2
                desiredY = focusedElementFrame.minY + fieldInset
            }
        } else if let targetWindowFrame = usable(targetWindowFrame) {
            desiredX = targetWindowFrame.midX - panelSize.width / 2
            desiredY = targetWindowFrame.minY + windowBottomInset
        } else {
            desiredX = screen.midX - panelSize.width / 2
            desiredY = screen.minY + screenEdgeInset
        }

        let minX = screen.minX + screenEdgeInset
        let maxX = screen.maxX - panelSize.width - screenEdgeInset
        let minY = screen.minY + screenEdgeInset
        let maxY = screen.maxY - panelSize.height - screenEdgeInset

        return CGPoint(
            x: min(max(desiredX, minX), maxX),
            y: min(max(desiredY, minY), maxY)
        )
    }

    private static func usable(_ frame: CGRect?) -> CGRect? {
        guard let frame, !frame.isNull, !frame.isEmpty,
              frame.width.isFinite, frame.height.isFinite,
              frame.minX.isFinite, frame.minY.isFinite else { return nil }
        return frame
    }

    private static func usableCaret(_ frame: CGRect?, within elementFrame: CGRect) -> CGRect? {
        guard let frame,
              !frame.isNull,
              frame.width >= 0,
              frame.height > 0,
              frame.midX.isFinite,
              frame.minY.isFinite,
              frame.midX >= elementFrame.minX - 2,
              frame.midX <= elementFrame.maxX + 2 else { return nil }
        return frame
    }

    private static func bestScreen(
        for targetWindowFrame: CGRect?,
        screenFrames: [CGRect],
        fallbackPoint: CGPoint
    ) -> CGRect {
        if let targetWindowFrame {
            let intersecting = screenFrames.max { lhs, rhs in
                intersectionArea(lhs, targetWindowFrame) < intersectionArea(rhs, targetWindowFrame)
            }
            if let intersecting, intersectionArea(intersecting, targetWindowFrame) > 0 {
                return intersecting
            }
        }
        return screenFrames.first(where: { $0.contains(fallbackPoint) }) ?? screenFrames[0]
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
