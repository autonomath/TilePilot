import AppKit

/// How one icon slot should be drawn.
enum SystemBarIconRendering: Equatable {
    /// Pixels cropped from the real menu bar.
    case matching(CGImage, size: CGSize, top: CGFloat)
    case symbol(String)
    case text(String)
    case appIcon(NSImage)

    static func == (lhs: SystemBarIconRendering, rhs: SystemBarIconRendering) -> Bool {
        switch (lhs, rhs) {
        case let (.matching(a, sizeA, topA), .matching(b, sizeB, topB)):
            return a === b && sizeA == sizeB && topA == topB
        case let (.symbol(a), .symbol(b)):
            return a == b
        case let (.text(a), .text(b)):
            return a == b
        case let (.appIcon(a), .appIcon(b)):
            return a === b
        default:
            return false
        }
    }
}

/// Everything the bar view draws. Built by `SystemBarController`; the view has no other state.
struct SystemBarContent {
    var titles: [SystemBarMenuTitle] = []
    var icons: [SystemBarStatusItem] = []
    var iconRenderings: [Int: SystemBarIconRendering] = [:]
    var plan = SystemBarLayoutPlan(slots: [], overflowMenuIndices: [], overflowIconIndices: [])
    /// The real bar's color in Matching mode; nil shows the standard bar material.
    var backgroundColor: CGColor?
    var backgroundIsDark = false
}

/// Draws the mirrored menu bar: titles on the left, icons on the right, with hover and
/// open-menu highlights. Uses top-left coordinates like the layout planner.
@MainActor
final class SystemBarView: NSView {
    static let appleMenuWidth: CGFloat = 34
    static let titlePadding: CGFloat = 10
    static let menuBarFont = NSFont.menuBarFont(ofSize: 0)

    var content = SystemBarContent() {
        didSet {
            if content.plan != oldValue.plan {
                rebuildToolTips()
            }
            let titlesChanged = content.titles.map { "\($0.title)|\($0.isEnabled)" } != oldValue.titles.map { "\($0.title)|\($0.isEnabled)" }
            let backgroundChanged = content.backgroundColor != oldValue.backgroundColor || content.backgroundIsDark != oldValue.backgroundIsDark
            if content.plan != oldValue.plan || titlesChanged || backgroundChanged {
                needsDisplay = true
            } else {
                // Only icon pixels changed (a new capture frame): redraw just those icons.
                for slot in content.plan.slots {
                    if case let .icon(index) = slot.kind, content.iconRenderings[index] != oldValue.iconRenderings[index] {
                        setNeedsDisplay(slotRect(slot))
                    }
                }
            }
        }
    }

    var openSlotIndex: Int? {
        didSet { if openSlotIndex != oldValue { needsDisplay = true } }
    }

    /// Called with the slot, the event, and whether it is a secondary click.
    var onClick: ((SystemBarSlot, NSEvent, Bool) -> Void)?

    private var hoveredSlotIndex: Int? {
        didSet { if hoveredSlotIndex != oldValue { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?
    private var pendingControlClick = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // An 8-bit layer: with the default extended-range format every redraw converts each icon
        // image to 16-bit float.
        wantsLayer = true
        layer?.contentsFormat = .RGBA8Uint
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.contentsFormat = .RGBA8Uint
        return layer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var mouseDownCanMoveWindow: Bool { false }

    /// Width a title needs on the bar when the app's real menu bar is hidden.
    static func measuredTitleWidth(_ title: SystemBarMenuTitle, isApplicationMenu: Bool) -> CGFloat {
        if title.isAppleMenu { return appleMenuWidth }
        if title.axWidth > 0 { return title.axWidth.rounded() }
        let font = isApplicationMenu ? NSFont.boldSystemFont(ofSize: menuBarFont.pointSize) : menuBarFont
        let width = (title.title as NSString).size(withAttributes: [.font: font]).width
        return (width + titlePadding * 2).rounded()
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoveredSlotIndex = slotIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hoveredSlotIndex = slotIndex(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSlotIndex = nil
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is a secondary click; act on release like a right click.
        if event.modifierFlags.contains(.control) {
            pendingControlClick = true
            return
        }
        handleClick(event, secondary: false)
    }

    override func mouseUp(with event: NSEvent) {
        guard pendingControlClick else { return }
        pendingControlClick = false
        handleClick(event, secondary: true)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Handled on release so a forwarded right click never overlaps the physical one.
    }

    override func rightMouseUp(with event: NSEvent) {
        handleClick(event, secondary: true)
    }

    private func handleClick(_ event: NSEvent, secondary: Bool) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = slotIndex(at: point) else { return }
        onClick?(content.plan.slots[index], event, secondary)
    }

    func slotIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return content.plan.slots.firstIndex { point.x >= $0.x && point.x < $0.maxX }
    }

    func slotRect(_ slot: SystemBarSlot) -> NSRect {
        NSRect(x: slot.x, y: 0, width: slot.width, height: bounds.height)
    }

    // MARK: - Tool tips

    private func rebuildToolTips() {
        removeAllToolTips()
        for (index, slot) in content.plan.slots.enumerated() {
            guard case .icon = slot.kind else { continue }
            addToolTip(slotRect(slot), owner: self, userData: UnsafeMutableRawPointer(bitPattern: index + 1))
        }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let data else { return "" }
        let index = Int(bitPattern: data) - 1
        guard content.plan.slots.indices.contains(index), case let .icon(iconIndex) = content.plan.slots[index].kind,
              content.icons.indices.contains(iconIndex) else {
            return ""
        }
        return content.icons[iconIndex].tooltip
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let backgroundColor = content.backgroundColor, let color = NSColor(cgColor: backgroundColor) {
            color.setFill()
            dirtyRect.fill()
        } else {
            NSColor.separatorColor.withAlphaComponent(0.5).setFill()
            NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        }

        for (index, slot) in content.plan.slots.enumerated() {
            let rect = slotRect(slot)
            guard rect.intersects(dirtyRect) else { continue }
            let isOpen = openSlotIndex == index
            let isHovered = hoveredSlotIndex == index && openSlotIndex == nil
            if isOpen || isHovered {
                drawHighlight(in: rect, strong: isOpen)
            }
            switch slot.kind {
            case let .menu(titleIndex):
                guard content.titles.indices.contains(titleIndex) else { continue }
                drawTitle(content.titles[titleIndex], isApplicationMenu: titleIndex == 1, in: rect, highlighted: isOpen)
            case let .icon(iconIndex):
                guard content.icons.indices.contains(iconIndex) else { continue }
                drawIcon(content.icons[iconIndex], rendering: content.iconRenderings[iconIndex], in: rect, highlighted: isOpen)
            case .overflow:
                drawText("»", font: NSFont.boldSystemFont(ofSize: Self.menuBarFont.pointSize + 1), in: rect, highlighted: isOpen, enabled: true)
            }
        }
    }

    private func drawHighlight(in rect: NSRect, strong: Bool) {
        let inset = rect.insetBy(dx: 0, dy: 3)
        let path = NSBezierPath(roundedRect: inset, xRadius: 5, yRadius: 5)
        if strong {
            NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        } else if content.backgroundColor != nil {
            (content.backgroundIsDark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.12)).setFill()
        } else {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
        }
        path.fill()
    }

    /// Text color on the current background: follows the real bar when its pixels are shown.
    private var foregroundColor: NSColor {
        guard content.backgroundColor != nil else { return .labelColor }
        return content.backgroundIsDark ? .white : .black
    }

    private var disabledForegroundColor: NSColor {
        guard content.backgroundColor != nil else { return .tertiaryLabelColor }
        return (content.backgroundIsDark ? NSColor.white : NSColor.black).withAlphaComponent(0.4)
    }

    private func drawTitle(_ title: SystemBarMenuTitle, isApplicationMenu: Bool, in rect: NSRect, highlighted: Bool) {
        if title.isAppleMenu {
            let color: NSColor = highlighted ? .white : (title.isEnabled ? foregroundColor : disabledForegroundColor)
            if let logo = NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "Apple")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)) {
                drawTemplate(logo, tinted: color, centeredIn: rect, size: nil)
            }
            return
        }
        let font = isApplicationMenu ? NSFont.boldSystemFont(ofSize: Self.menuBarFont.pointSize) : Self.menuBarFont
        drawText(title.title, font: font, in: rect, highlighted: highlighted, enabled: title.isEnabled)
    }

    private func drawIcon(_ icon: SystemBarStatusItem, rendering: SystemBarIconRendering?, in rect: NSRect, highlighted: Bool) {
        switch rendering {
        case let .matching(image, size, top):
            let target = NSRect(
                x: rect.minX + ((rect.width - size.width) / 2).rounded(),
                y: min(max(0, top), max(0, rect.height - size.height)),
                width: size.width,
                height: size.height
            )
            NSImage(cgImage: image, size: size).draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        case let .symbol(name):
            if let image = NSImage(systemSymbolName: name, accessibilityDescription: icon.tooltip)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)) {
                drawTemplate(image, tinted: highlighted ? .white : foregroundColor, centeredIn: rect, size: nil)
            }
        case let .text(text):
            drawText(text, font: Self.menuBarFont, in: rect, highlighted: highlighted, enabled: true)
        case let .appIcon(image):
            let side: CGFloat = 18
            let target = NSRect(x: rect.midX - side / 2, y: ((rect.height - side) / 2).rounded(), width: side, height: side)
            image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        case nil:
            drawText(icon.title.isEmpty ? "•" : icon.title, font: Self.menuBarFont, in: rect, highlighted: highlighted, enabled: true)
        }
    }

    private func drawTemplate(_ image: NSImage, tinted color: NSColor, centeredIn rect: NSRect, size: CGSize?) {
        let imageSize = size ?? image.size
        let target = NSRect(
            x: rect.midX - imageSize.width / 2,
            y: ((rect.height - imageSize.height) / 2).rounded(),
            width: imageSize.width,
            height: imageSize.height
        )
        let tinted = NSImage(size: imageSize, flipped: false) { bounds in
            image.draw(in: bounds)
            color.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawText(_ text: String, font: NSFont, in rect: NSRect, highlighted: Bool, enabled: Bool) {
        let color: NSColor = highlighted ? .white : (enabled ? foregroundColor : disabledForegroundColor)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: rect.midX - size.width / 2,
            y: ((rect.height - size.height) / 2).rounded()
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
