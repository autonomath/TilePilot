#if canImport(XCTest)
import AppKit
import XCTest
@testable import TilePilot

@MainActor
final class KeyboardLayerTextPasterTests: XCTestCase {
    func testPastesTheTextMarkedTransientThenRestoresEveryType() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let original = NSPasteboardItem()
        original.setString("Copied", forType: .string)
        original.setData(Data("<b>Copied</b>".utf8), forType: .html)
        pasteboard.clearContents()
        pasteboard.writeObjects([original])
        var presses = 0
        let paster = KeyboardLayerTextPaster(pasteboard: pasteboard, restoreDelay: .seconds(3600)) { presses += 1 }

        paster.paste("Line one\nLine two")

        XCTAssertEqual(presses, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "Line one\nLine two")
        XCTAssertEqual(pasteboard.types?.contains(KeyboardLayerTextPaster.transientType), true)
        paster.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied")
        XCTAssertEqual(pasteboard.data(forType: .html), Data("<b>Copied</b>".utf8))
        XCTAssertEqual(pasteboard.types?.contains(KeyboardLayerTextPaster.transientType), false)
    }

    func testANewerCopyIsLeftAlone() {
        let pasteboard = makePasteboard(copied: "Copied")
        defer { pasteboard.releaseGlobally() }
        let paster = KeyboardLayerTextPaster(pasteboard: pasteboard, restoreDelay: .seconds(3600)) {}

        paster.paste("Snippet")
        copy("Newer", to: pasteboard)
        paster.restore()

        XCTAssertEqual(pasteboard.string(forType: .string), "Newer")
    }

    func testBackToBackPastesBringBackTheClipboardFromBeforeTheFirst() {
        let pasteboard = makePasteboard(copied: "Copied")
        defer { pasteboard.releaseGlobally() }
        let paster = KeyboardLayerTextPaster(pasteboard: pasteboard, restoreDelay: .seconds(3600)) {}

        paster.paste("One")
        paster.paste("Two")
        XCTAssertEqual(pasteboard.string(forType: .string), "Two")
        paster.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied")

        // Something copied between two pastes is what comes back.
        paster.paste("Three")
        copy("Between", to: pasteboard)
        paster.paste("Four")
        paster.restore()
        XCTAssertEqual(pasteboard.string(forType: .string), "Between")
    }

    func testRestoresByItselfAfterTheDelay() async throws {
        let pasteboard = makePasteboard(copied: "Copied")
        defer { pasteboard.releaseGlobally() }
        let paster = KeyboardLayerTextPaster(pasteboard: pasteboard, restoreDelay: .milliseconds(50)) {}

        paster.paste("Snippet")
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(pasteboard.string(forType: .string), "Copied")
    }

    private func makePasteboard(copied: String? = nil) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TilePilotTests.\(UUID().uuidString)"))
        if let copied { copy(copied, to: pasteboard) }
        return pasteboard
    }

    private func copy(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
#endif
