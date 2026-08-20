import AppKit
import Foundation

struct PasteboardSnapshot: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        struct Representation: Codable, Equatable, Sendable {
            let type: String
            let data: Data
        }
        let representations: [Representation]
    }

    let items: [Item]

    @MainActor
    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(representations: item.types.compactMap { type in
                item.data(forType: type).map { Item.Representation(type: type.rawValue, data: $0) }
            })
        }
        return PasteboardSnapshot(items: items)
    }
}
@MainActor
protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }
    func snapshot() -> PasteboardSnapshot
    @discardableResult func replaceWithText(_ text: String) -> Int
    @discardableResult func restore(_ snapshot: PasteboardSnapshot) -> Int
}

@MainActor
final class SystemPasteboard: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot {
        .capture(from: pasteboard)
    }

    @discardableResult
    func replaceWithText(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    @discardableResult
    func restore(_ snapshot: PasteboardSnapshot) -> Int {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.map { stored in
            let item = NSPasteboardItem()
            for representation in stored.representations {
                item.setData(representation.data, forType: NSPasteboard.PasteboardType(representation.type))
            }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
        return pasteboard.changeCount
    }
}
