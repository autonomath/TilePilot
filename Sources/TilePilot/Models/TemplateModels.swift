import CoreGraphics
import Foundation

enum TemplateSlotSplitAxis: String, Sendable {
    case vertical
    case horizontal
}

struct DisplayShapeKey: Codable, Hashable, Sendable {
    let aspectRatio: Double

    static let matchTolerance: Double = 0.05

    init(aspectRatio: Double) {
        self.aspectRatio = max(0.1, aspectRatio)
    }

    static func from(width: Double, height: Double) -> DisplayShapeKey? {
        guard width > 1, height > 1 else { return nil }
        let raw = width / height
        let rounded = (raw * 1_000).rounded() / 1_000
        return DisplayShapeKey(aspectRatio: rounded)
    }

    func matches(width: Double, height: Double) -> Bool {
        guard width > 1, height > 1 else { return false }
        return abs((width / height) - aspectRatio) <= Self.matchTolerance
    }

    var description: String {
        String(format: "%.2f", aspectRatio)
    }
}

struct WindowLayoutSlot: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let normalizedX: Double
    let normalizedY: Double
    let normalizedWidth: Double
    let normalizedHeight: Double
    let zIndex: Int
    let allowedApps: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case normalizedX
        case normalizedY
        case normalizedWidth
        case normalizedHeight
        case zIndex
        case allowedApps
    }

    init(
        id: UUID = UUID(),
        normalizedX: Double,
        normalizedY: Double,
        normalizedWidth: Double,
        normalizedHeight: Double,
        zIndex: Int = 0,
        allowedApps: [String] = []
    ) {
        self.id = id
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
        self.zIndex = zIndex
        self.allowedApps = canonicalizeAppRuleList(allowedApps)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        normalizedX = try container.decode(Double.self, forKey: .normalizedX)
        normalizedY = try container.decode(Double.self, forKey: .normalizedY)
        normalizedWidth = try container.decode(Double.self, forKey: .normalizedWidth)
        normalizedHeight = try container.decode(Double.self, forKey: .normalizedHeight)
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        allowedApps = canonicalizeAppRuleList(
            try container.decodeIfPresent([String].self, forKey: .allowedApps) ?? []
        )
    }

    var normalizedRect: CGRect {
        CGRect(x: normalizedX, y: normalizedY, width: normalizedWidth, height: normalizedHeight)
    }

    func with(rect: CGRect? = nil, zIndex: Int? = nil, allowedApps: [String]? = nil) -> WindowLayoutSlot {
        let targetRect = rect ?? normalizedRect
        return WindowLayoutSlot(
            id: id,
            normalizedX: targetRect.origin.x,
            normalizedY: targetRect.origin.y,
            normalizedWidth: targetRect.size.width,
            normalizedHeight: targetRect.size.height,
            zIndex: zIndex ?? self.zIndex,
            allowedApps: allowedApps ?? self.allowedApps
        )
    }
}

struct WindowLayoutTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let name: String
    let sourceDisplayName: String
    let displayShapeKey: DisplayShapeKey
    let slots: [WindowLayoutSlot]

    init(
        id: UUID = UUID(),
        name: String,
        sourceDisplayName: String,
        displayShapeKey: DisplayShapeKey,
        slots: [WindowLayoutSlot]
    ) {
        self.id = id
        self.name = name
        self.sourceDisplayName = sourceDisplayName
        self.displayShapeKey = displayShapeKey
        self.slots = WindowLayoutTemplate.sortedSlots(slots)
    }

    func with(
        name: String? = nil,
        sourceDisplayName: String? = nil,
        displayShapeKey: DisplayShapeKey? = nil,
        slots: [WindowLayoutSlot]? = nil
    ) -> WindowLayoutTemplate {
        WindowLayoutTemplate(
            id: id,
            name: name ?? self.name,
            sourceDisplayName: sourceDisplayName ?? self.sourceDisplayName,
            displayShapeKey: displayShapeKey ?? self.displayShapeKey,
            slots: slots ?? self.slots
        )
    }

    static func sortedSlots(_ slots: [WindowLayoutSlot]) -> [WindowLayoutSlot] {
        slots.sorted { lhs, rhs in
            if abs(lhs.normalizedY - rhs.normalizedY) > 0.02 { return lhs.normalizedY < rhs.normalizedY }
            if abs(lhs.normalizedX - rhs.normalizedX) > 0.02 { return lhs.normalizedX < rhs.normalizedX }
            if abs(lhs.normalizedHeight - rhs.normalizedHeight) > 0.0001 { return lhs.normalizedHeight > rhs.normalizedHeight }
            if abs(lhs.normalizedWidth - rhs.normalizedWidth) > 0.0001 { return lhs.normalizedWidth > rhs.normalizedWidth }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct TemplateDisplayOption: Identifiable, Hashable, Sendable {
    let id: String
    let displayID: Int?
    let name: String
    let frameWidth: Double
    let frameHeight: Double
    let shapeKey: DisplayShapeKey

    init(displayID: Int?, name: String, frameWidth: Double, frameHeight: Double, shapeKey: DisplayShapeKey) {
        self.displayID = displayID
        self.name = name
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.shapeKey = shapeKey
        if let displayID {
            self.id = "display-\(displayID)"
        } else {
            self.id = "shape-\(name)-\(shapeKey.description)"
        }
    }
}

func clampedNormalizedTemplateRect(_ rect: CGRect) -> CGRect {
    let minSize: CGFloat = 0.04
    var x = max(0, min(1, rect.origin.x))
    var y = max(0, min(1, rect.origin.y))
    var width = max(minSize, min(1, rect.size.width))
    var height = max(minSize, min(1, rect.size.height))

    if x + width > 1 { x = max(0, 1 - width) }
    if y + height > 1 { y = max(0, 1 - height) }
    if x + width > 1 { width = max(minSize, 1 - x) }
    if y + height > 1 { height = max(minSize, 1 - y) }

    return CGRect(x: x, y: y, width: width, height: height)
}

func normalizedTemplateRect(from rawRect: CGRect, in canvasSize: CGSize) -> CGRect {
    guard canvasSize.width > 1, canvasSize.height > 1 else { return .zero }
    let x1 = min(rawRect.minX, rawRect.maxX) / canvasSize.width
    let y1 = min(rawRect.minY, rawRect.maxY) / canvasSize.height
    let x2 = max(rawRect.minX, rawRect.maxX) / canvasSize.width
    let y2 = max(rawRect.minY, rawRect.maxY) / canvasSize.height
    return clampedNormalizedTemplateRect(
        CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    )
}

func canvasRect(for slot: WindowLayoutSlot, in canvasSize: CGSize) -> CGRect {
    CGRect(
        x: slot.normalizedX * canvasSize.width,
        y: slot.normalizedY * canvasSize.height,
        width: slot.normalizedWidth * canvasSize.width,
        height: slot.normalizedHeight * canvasSize.height
    )
}

func canvasOrderedTemplateSlots(_ slots: [WindowLayoutSlot]) -> [WindowLayoutSlot] {
    slots.sorted { lhs, rhs in
        if lhs.zIndex != rhs.zIndex { return lhs.zIndex < rhs.zIndex }
        let geometric = WindowLayoutTemplate.sortedSlots([lhs, rhs])
        return geometric.first?.id == lhs.id
    }
}

func normalizedTemplateSlotZOrder(_ slots: [WindowLayoutSlot]) -> [WindowLayoutSlot] {
    canvasOrderedTemplateSlots(slots).enumerated().map { index, slot in
        slot.with(zIndex: index)
    }
}

func normalizedTemplateSlotZOrderPreservingOrder(_ slots: [WindowLayoutSlot]) -> [WindowLayoutSlot] {
    slots.enumerated().map { index, slot in
        slot.with(zIndex: index)
    }
}

func splitTemplateSlotRect(_ rect: CGRect, axis: TemplateSlotSplitAxis) -> (CGRect, CGRect)? {
    switch axis {
    case .vertical:
        guard rect.width / 2 >= 0.04 else { return nil }
        let halfWidth = rect.width / 2
        let left = CGRect(x: rect.minX, y: rect.minY, width: halfWidth, height: rect.height)
        let right = CGRect(x: rect.minX + halfWidth, y: rect.minY, width: rect.width - halfWidth, height: rect.height)
        return (clampedNormalizedTemplateRect(left), clampedNormalizedTemplateRect(right))
    case .horizontal:
        guard rect.height / 2 >= 0.04 else { return nil }
        let halfHeight = rect.height / 2
        let top = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: halfHeight)
        let bottom = CGRect(x: rect.minX, y: rect.minY + halfHeight, width: rect.width, height: rect.height - halfHeight)
        return (clampedNormalizedTemplateRect(top), clampedNormalizedTemplateRect(bottom))
    }
}
