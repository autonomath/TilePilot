import AppKit
import Combine
import CoreGraphics

@MainActor
final class WorkSetBackdropController {
    private final class BackdropPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class BackdropPanelView: NSView {
        var onClick: (() -> Void)?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func update(fillColor: NSColor) {
            wantsLayer = true
            layer?.backgroundColor = fillColor.cgColor
        }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    private let model: AppModel
    private var cancellables: Set<AnyCancellable> = []
    private var panelsByScope: [WorkSetScopeKey: BackdropPanel] = [:]

    init(model: AppModel) {
        self.model = model
        bind()
    }

    private func bind() {
        Publishers.CombineLatest(
            model.$workSetBackdropPresentations,
            model.$recentWindowTilerBackdropPresentations
        )
            .sink { [weak self] workSetPresentations, pickerPresentations in
                self?.applyBackdropPresentations(
                    self?.combinedPresentations(
                        workSet: workSetPresentations,
                        picker: pickerPresentations
                    ) ?? [:]
                )
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reapplyCurrentPresentations()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reapplyCurrentPresentations()
            }
            .store(in: &cancellables)
    }

    private func reapplyCurrentPresentations() {
        applyBackdropPresentations(
            combinedPresentations(
                workSet: model.workSetBackdropPresentations,
                picker: model.recentWindowTilerBackdropPresentations
            )
        )
    }

    private func combinedPresentations(
        workSet: [WorkSetScopeKey: WorkSetBackdropPresentation],
        picker: [WorkSetScopeKey: WorkSetBackdropPresentation]
    ) -> [WorkSetScopeKey: WorkSetBackdropPresentation] {
        workSet.merging(picker) { _, pickerPresentation in pickerPresentation }
    }

    private func applyBackdropPresentations(_ presentations: [WorkSetScopeKey: WorkSetBackdropPresentation]) {
        let activeScopes = Set(presentations.keys)

        for (scopeKey, panel) in panelsByScope where !activeScopes.contains(scopeKey) {
            dispose(panel)
            panelsByScope.removeValue(forKey: scopeKey)
        }

        for (scopeKey, presentation) in presentations {
            let panel = panelsByScope[scopeKey] ?? createPanel(scopeKey: scopeKey)
            panelsByScope[scopeKey] = panel
            update(panel: panel, with: presentation)
        }
    }

    private func createPanel(scopeKey: WorkSetScopeKey) -> BackdropPanel {
        let frame = NSRect(origin: .zero, size: NSSize(width: 600, height: 400))
        let panel = BackdropPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.level = .normal
        panel.collectionBehavior = [
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient,
            .stationary,
        ]
        panel.animationBehavior = .none
        panel.isMovable = false
        panel.isMovableByWindowBackground = false

        let view = BackdropPanelView(frame: frame)
        view.onClick = { [weak self] in
            self?.model.dismissActiveBackdrop(for: scopeKey)
        }
        panel.contentView = view
        return panel
    }

    private func update(panel: BackdropPanel, with presentation: WorkSetBackdropPresentation) {
        let displayRect = convertTopOriginRectToAppKit(
            CGRect(
                x: presentation.display.frameX,
                y: presentation.display.frameY,
                width: presentation.display.frameW,
                height: presentation.display.frameH
            )
        )
        let targetScreen = bestScreen(for: displayRect)
        let targetFrame = (targetScreen?.visibleFrame ?? displayRect).integral
        let fillColor = presentation.color.nsColor

        let backdropView: BackdropPanelView
        if let existing = panel.contentView as? BackdropPanelView {
            backdropView = existing
        } else {
            backdropView = BackdropPanelView(frame: NSRect(origin: .zero, size: targetFrame.size))
            backdropView.onClick = { [weak self] in
                self?.model.dismissActiveBackdrop(for: presentation.scopeKey)
            }
            panel.contentView = backdropView
        }

        panel.backgroundColor = fillColor
        backdropView.frame = NSRect(origin: .zero, size: targetFrame.size)
        backdropView.update(fillColor: fillColor)
        panel.setFrame(targetFrame, display: true)

        if let anchorWindow = presentation.anchorWindow,
           let windowNumber = targetWindowNumber(for: anchorWindow) {
            panel.order(.above, relativeTo: Int(windowNumber))
        } else {
            panel.orderFront(nil)
        }
    }

    private func dispose(_ panel: BackdropPanel) {
        panel.contentView = nil
        panel.orderOut(nil)
        panel.close()
    }

    private func bestScreen(for rect: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            let intersection = rect.intersection(screen.frame)
            if intersection.isNull || intersection.isEmpty { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    private func resolvedGlobalRect(for window: WindowState) -> CGRect {
        convertTopOriginRectToAppKit(
            CGRect(
                x: window.frameX,
                y: window.frameY,
                width: window.frameW,
                height: window.frameH
            )
        )
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

    private func targetWindowNumber(for window: WindowState) -> CGWindowID? {
        guard let rawInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              !rawInfo.isEmpty else {
            return nil
        }

        if let orderIndex = window.windowServerOrderIndex,
           rawInfo.indices.contains(orderIndex),
           let number = rawInfo[orderIndex][kCGWindowNumber as String] as? NSNumber {
            return CGWindowID(number.uint32Value)
        }

        let targetRect = resolvedGlobalRect(for: window)
        var bestNumber: CGWindowID?
        var bestScore: CGFloat = .greatestFiniteMagnitude

        for entry in rawInfo {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == window.pid,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let cgRect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            let rect = convertTopOriginRectToAppKit(cgRect)
            if rect.isEmpty { continue }

            let dx = abs(rect.minX - targetRect.minX)
            let dy = abs(rect.minY - targetRect.minY)
            let dw = abs(rect.width - targetRect.width)
            let dh = abs(rect.height - targetRect.height)
            let score = (dx * 2.0) + (dy * 2.0) + dw + dh

            if score < bestScore {
                bestScore = score
                bestNumber = CGWindowID(number)
            }
        }

        return bestNumber
    }
}
