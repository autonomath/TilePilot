import AppKit
import Combine
import SwiftUI

private final class RecentWindowTilerPanel: NSPanel {
    /// Handles a key press without Command, Option or Control; returns false to pass it on.
    var onKey: ((UInt16) -> Bool)?

    // Caught before dispatch, so a focused button or the mode control can't swallow them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           onKey?(event.keyCode) == true {
            return
        }
        super.sendEvent(event)
    }
}

@MainActor
final class RecentWindowTilerWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var cancellable: AnyCancellable?
    private var isClosingFromModel = false
    private let defaultContentWidth: CGFloat = 650
    private let defaultContentHeight: CGFloat = 820

    init(model: AppModel) {
        self.model = model

        let panel = RecentWindowTilerPanel(
            contentRect: NSRect(x: 0, y: 0, width: defaultContentWidth, height: defaultContentHeight),
            // Non-activating: macOS won't activate TilePilot for a shortcut, so the picker takes
            // keyboard focus without it, in front of the app you were using.
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Windows picker"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace]
        panel.contentMinSize = NSSize(width: 500, height: 320)
        panel.contentViewController = NSHostingController(rootView: RecentWindowTilerPickerView(model: model))
        panel.onKey = { [weak model] keyCode in
            guard let model else { return false }
            switch keyCode {
            case 36, 76: model.applyRecentWindowTilerSelection() // Return, keypad Enter
            case 49: model.toggleRecentWindowTilerHighlightedSelection() // Space
            case 125: model.moveRecentWindowTilerHighlight(by: 1) // Down arrow
            case 126: model.moveRecentWindowTilerHighlight(by: -1) // Up arrow
            case 53: model.dismissRecentWindowTiler() // Esc
            default: return false
            }
            return true
        }

        super.init(window: panel)
        panel.delegate = self

        cancellable = model.$recentWindowTilerState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.syncPresentation(state)
            }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosingFromModel else { return }
        model.dismissRecentWindowTiler()
    }

    private func syncPresentation(_ state: RecentWindowTilerPresentationState?) {
        guard let window else { return }
        guard let state else {
            if window.isVisible {
                isClosingFromModel = true
                window.close()
                isClosingFromModel = false
            }
            return
        }

        let shouldCenter = !window.isVisible
        if shouldCenter {
            resizeWindow(for: state)
            centerWindowOnTargetDisplay(for: state)
        }
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func resizeWindow(for state: RecentWindowTilerPresentationState) {
        guard let window else { return }
        let visibleRows = min(max(state.candidates.count, 1), 10)
        let rowHeight: CGFloat = 42
        let rowSpacing: CGFloat = 6
        let listHeight = CGFloat(visibleRows) * rowHeight + CGFloat(max(0, visibleRows - 1)) * rowSpacing
        let fixedContentHeight: CGFloat = state.mode == .template ? 222 : 158
        let contentHeight = max(defaultContentHeight, (fixedContentHeight + listHeight) * 1.3)
        window.setContentSize(NSSize(width: defaultContentWidth, height: contentHeight))
    }

    private func centerWindowOnTargetDisplay(for state: RecentWindowTilerPresentationState) {
        guard let window else { return }
        let targetFrame = targetVisibleFrame(for: state) ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let targetFrame else {
            window.center()
            return
        }

        let windowFrame = window.frame
        let width = min(windowFrame.width, targetFrame.width)
        let height = min(windowFrame.height, targetFrame.height)
        let x = targetFrame.minX + ((targetFrame.width - width) / 2)
        let y = targetFrame.minY + ((targetFrame.height - height) / 2)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func targetVisibleFrame(for state: RecentWindowTilerPresentationState) -> NSRect? {
        guard let displayFrame = state.displayFrame else { return nil }
        let appKitDisplayFrame = convertTopOriginRectToAppKit(displayFrame)
        var bestScreen: NSScreen?
        var bestArea: CGFloat = 0

        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(appKitDisplayFrame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestScreen = screen
            }
        }

        return bestScreen?.visibleFrame
    }

    private func convertTopOriginRectToAppKit(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return rect }

        let referenceMaxY = screens.first(where: { screen in
            abs(screen.frame.minX) < 0.5 && abs(screen.frame.minY) < 0.5
        })?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? screens.map(\.frame.maxY).min()
            ?? rect.maxY

        return CGRect(
            x: rect.origin.x,
            y: referenceMaxY - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
