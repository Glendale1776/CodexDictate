import XCTest
@testable import CodexDictate

final class HUDPlacementTests: XCTestCase {
    private let panelSize = CGSize(width: 90, height: 1.25)
    private let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondary = CGRect(x: 1920, y: 0, width: 2560, height: 1440)

    func testIndicatorFollowsWindowOnSecondaryScreen() {
        let target = CGRect(x: 2100, y: 40, width: 1600, height: 1200)
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: nil,
            focusedCaretFrame: nil,
            targetWindowFrame: target,
            screenFrames: [primary, secondary],
            fallbackPoint: CGPoint(x: 100, y: 100)
        )

        XCTAssertEqual(origin?.x, target.midX - panelSize.width / 2)
        XCTAssertEqual(origin?.y, target.minY + 14)
        XCTAssertTrue(secondary.contains(origin!))
    }

    func testIndicatorClampsInsideTargetScreen() {
        let target = CGRect(x: 1900, y: -30, width: 100, height: 500)
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: nil,
            focusedCaretFrame: nil,
            targetWindowFrame: target,
            screenFrames: [primary, secondary],
            fallbackPoint: .zero
        )

        XCTAssertEqual(origin?.x, secondary.minX + 10)
        XCTAssertEqual(origin?.y, secondary.minY + 10)
    }

    func testFallbackUsesScreenContainingPointer() {
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: nil,
            focusedCaretFrame: nil,
            targetWindowFrame: nil,
            screenFrames: [primary, secondary],
            fallbackPoint: CGPoint(x: 3000, y: 500)
        )

        XCTAssertEqual(origin?.x, secondary.midX - panelSize.width / 2)
        XCTAssertEqual(origin?.y, secondary.minY + 10)
    }

    func testIndicatorStaysInsideFocusedFieldWhenCaretIsUnavailable() {
        let field = CGRect(x: 2300, y: 1300, width: 900, height: 34)
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: field,
            focusedCaretFrame: nil,
            targetWindowFrame: CGRect(x: 2100, y: 100, width: 1400, height: 1350),
            screenFrames: [primary, secondary],
            fallbackPoint: CGPoint(x: 100, y: 100)
        )

        XCTAssertEqual(origin?.x, field.midX - panelSize.width / 2)
        XCTAssertEqual(origin?.y, field.minY + 2)
        XCTAssertTrue(secondary.contains(origin!))
    }

    func testIndicatorFollowsInsertionCaretAcrossTextDirections() {
        let field = CGRect(x: 2300, y: 1300, width: 900, height: 34)
        let leftCaret = CGRect(x: 2320, y: 1306, width: 1, height: 20)
        let rightCaret = CGRect(x: 3180, y: 1306, width: 1, height: 20)

        let leftOrigin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: field,
            focusedCaretFrame: leftCaret,
            targetWindowFrame: nil,
            screenFrames: [primary, secondary],
            fallbackPoint: .zero
        )
        let rightOrigin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: field,
            focusedCaretFrame: rightCaret,
            targetWindowFrame: nil,
            screenFrames: [primary, secondary],
            fallbackPoint: .zero
        )

        XCTAssertEqual(leftOrigin?.x, leftCaret.midX)
        XCTAssertEqual(rightOrigin?.x, rightCaret.midX - panelSize.width)
        XCTAssertEqual(leftOrigin?.y, leftCaret.minY - panelSize.height - 2)
        XCTAssertEqual(leftOrigin?.y, rightOrigin?.y)
        XCTAssertGreaterThanOrEqual(leftOrigin!.x, field.minX)
        XCTAssertLessThanOrEqual(leftOrigin!.x + panelSize.width, field.maxX)
        XCTAssertGreaterThanOrEqual(rightOrigin!.x, field.minX)
        XCTAssertLessThanOrEqual(rightOrigin!.x + panelSize.width, field.maxX)
    }

    func testIndicatorUsesCaretLineInsteadOfBottomOfTallEditor() {
        let tallEditor = CGRect(x: 2200, y: 300, width: 1000, height: 900)
        let topLineCaret = CGRect(x: 2230, y: 1160, width: 1, height: 22)
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: tallEditor,
            focusedCaretFrame: topLineCaret,
            targetWindowFrame: nil,
            screenFrames: [primary, secondary],
            fallbackPoint: .zero
        )

        XCTAssertEqual(origin?.x, topLineCaret.midX)
        XCTAssertEqual(origin?.y, topLineCaret.minY - panelSize.height - 2)
        XCTAssertGreaterThan(origin!.y, tallEditor.midY)
    }

    func testIndicatorIsClampedVerticallyInsideFocusedField() {
        let field = CGRect(x: 2300, y: 1300, width: 900, height: 34)
        let caretAtBottom = CGRect(x: 2320, y: 1300, width: 1, height: 20)
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: field,
            focusedCaretFrame: caretAtBottom,
            targetWindowFrame: nil,
            screenFrames: [primary, secondary],
            fallbackPoint: .zero
        )

        XCTAssertEqual(origin?.x, caretAtBottom.midX)
        XCTAssertEqual(origin?.y, field.minY + 2)
        XCTAssertGreaterThanOrEqual(origin!.y, field.minY)
        XCTAssertLessThanOrEqual(origin!.y + panelSize.height, field.maxY)
    }

    func testWebEditorFallbackUsesLeadingEdgeAndTopLineForBothDirections() {
        let editor = CGRect(x: 2200, y: 300, width: 1000, height: 900)
        let leftToRight = CaretFallbackPlacement.frame(in: editor, rightToLeft: false)
        let rightToLeft = CaretFallbackPlacement.frame(in: editor, rightToLeft: true)

        XCTAssertEqual(leftToRight.midX, editor.minX + 2.5)
        XCTAssertEqual(rightToLeft.midX, editor.maxX - 1.5)
        XCTAssertEqual(leftToRight.maxY, editor.maxY - 8)
        XCTAssertEqual(rightToLeft.maxY, editor.maxY - 8)
    }

    func testInvalidWebEditorCaretIsReplacedBeforeHUDPlacement() {
        let editor = CGRect(x: 20, y: 500, width: 1820, height: 350)
        let incorrectlyReportedCaret = CGRect(x: 340, y: 40, width: 1, height: 20)

        let resolved = CaretFrameResolver.frame(
            reportedCaret: incorrectlyReportedCaret,
            in: editor,
            rightToLeft: false
        )
        let origin = HUDPlacement.origin(
            panelSize: panelSize,
            focusedElementFrame: editor,
            focusedCaretFrame: resolved,
            targetWindowFrame: nil,
            screenFrames: [primary],
            fallbackPoint: .zero
        )

        XCTAssertEqual(resolved.midX, editor.minX + 2.5)
        XCTAssertEqual(resolved.maxY, editor.maxY - 8)
        XCTAssertEqual(origin?.x, resolved.midX)
        XCTAssertEqual(origin?.y, resolved.minY - panelSize.height - 2)
        XCTAssertGreaterThan(origin!.y, editor.midY)
    }

    func testValidReportedCaretIsPreserved() {
        let editor = CGRect(x: 20, y: 500, width: 1820, height: 350)
        let reportedCaret = CGRect(x: 48, y: 808, width: 1, height: 20)

        XCTAssertEqual(
            CaretFrameResolver.frame(
                reportedCaret: reportedCaret,
                in: editor,
                rightToLeft: false
            ),
            reportedCaret
        )
    }

    func testVSCodePlaceholderReportedAsValueIsTreatedAsEmpty() {
        XCTAssertEqual(
            EditableTextContent.effectiveLength(
                value: "\nAsk for follow-up changes",
                placeholder: "Ask for follow-up changes"
            ),
            0
        )
        XCTAssertEqual(
            EditableTextContent.effectiveLength(
                value: "Actual dictated text",
                placeholder: "Ask for follow-up changes"
            ),
            "Actual dictated text".utf16.count
        )
    }
}
