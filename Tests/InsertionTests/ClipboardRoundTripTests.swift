import AppKit
import Testing
@testable import Insertion

@MainActor
@Suite struct ClipboardRoundTripTests {
    /// A private pasteboard, so the tests never touch the real clipboard.
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("flow-test-\(UUID().uuidString)"))
    }

    @Test func restoresTextAndCustomTypes() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let custom = NSPasteboard.PasteboardType("com.example.custom")
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3, 4]), forType: custom)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let saved = ClipboardPaster.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        ClipboardPaster.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "original")
        #expect(pasteboard.pasteboardItems?.first?.data(forType: custom) == Data([1, 2, 3, 4]))
    }

    @Test func restoresSeveralItems() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }

        let first = NSPasteboardItem()
        first.setString("one", forType: .string)
        let second = NSPasteboardItem()
        second.setString("two", forType: .string)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let saved = ClipboardPaster.snapshot(of: pasteboard)
        pasteboard.clearContents()
        ClipboardPaster.restore(saved, to: pasteboard)

        #expect(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["one", "two"])
    }

    @Test func restoringAnEmptyClipboardLeavesItEmpty() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()

        let saved = ClipboardPaster.snapshot(of: pasteboard)
        pasteboard.setString("dictated text", forType: .string)
        ClipboardPaster.restore(saved, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func emptyTextIsNeverInserted() async {
        let paster = ClipboardPaster(pasteboard: makePasteboard())
        #expect(await paster.insert("", into: nil) == .skipped(.emptyText))
    }
}
