import AppKit

/// Types a block of text by pasting it, then puts the clipboard back.
@MainActor
final class KeyboardLayerTextPaster {
    /// Clipboard managers skip items carrying this type (nspasteboard.org).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let restoreDelay: Duration
    private let press: () -> Void
    /// The user's clipboard, kept until it goes back.
    private var saved: [NSPasteboardItem]?
    private var pastedChangeCount: Int?
    private var restoreTask: Task<Void, Never>?

    /// `press` presses ⌘V in the front app.
    init(pasteboard: NSPasteboard = .general, restoreDelay: Duration = .seconds(1), press: @escaping () -> Void) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.press = press
    }

    func paste(_ text: String) {
        // Back-to-back pastes keep the clipboard saved by the first, unless something was copied
        // in between.
        if saved == nil || pasteboard.changeCount != pastedChangeCount {
            saved = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) { copy.setData(data, forType: type) }
                }
                return copy
            }
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        pastedChangeCount = pasteboard.changeCount
        press()
        restoreTask?.cancel()
        restoreTask = Task { [weak self, restoreDelay] in
            try? await Task.sleep(for: restoreDelay)
            guard !Task.isCancelled else { return }
            self?.restore()
        }
    }

    /// Puts the saved clipboard back, unless something new was copied since the paste.
    func restore() {
        restoreTask?.cancel()
        restoreTask = nil
        defer {
            saved = nil
            pastedChangeCount = nil
        }
        guard let saved, pasteboard.changeCount == pastedChangeCount else { return }
        pasteboard.clearContents()
        if !saved.isEmpty { pasteboard.writeObjects(saved) }
    }
}
