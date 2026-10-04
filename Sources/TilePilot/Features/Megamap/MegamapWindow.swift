import AppKit
import Combine
import SwiftUI

private final class MegamapWindow: NSWindow {
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
private final class MegamapDisplayWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let displayID: Int

    private enum PersistedWindowKeys {
        static func width(for displayID: Int) -> String { "TilePilot.megamapWindow.\(displayID).width" }
        static func height(for displayID: Int) -> String { "TilePilot.megamapWindow.\(displayID).height" }
        static func frameAutosaveName(for displayID: Int) -> String { "TilePilotMegamapWindow.\(displayID)" }
    }

    init(model: AppModel, displayID: Int) {
        self.model = model
        self.displayID = displayID
        let hosting = MegamapDisplayWindowController.makeHostingController(model: model, displayID: displayID)

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 900)
        let window = MegamapWindow(contentViewController: hosting)
        window.title = "MegaMap"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setFrame(visibleFrame, display: false)
        window.minSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        _ = window.setFrameUsingName(PersistedWindowKeys.frameAutosaveName(for: displayID))
        Self.restorePersistedSize(for: window, displayID: displayID)
        window.setFrameAutosaveName(PersistedWindowKeys.frameAutosaveName(for: displayID))
        window.onEscape = {
            NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)
        }

        super.init(window: window)
        shouldCascadeWindows = true
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func show(makeKey: Bool) {
        ensureContentLoaded()
        window?.alphaValue = 1
        showWindow(nil)
        snapToDisplayVisibleFrame()
        if makeKey {
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }

    func hideImmediately() {
        guard let window else { return }
        window.alphaValue = 0
        window.orderOut(nil)
        unloadContent()
    }

    func persistCurrentWindowSize() {
        guard let window else { return }
        let defaults = UserDefaults.standard
        defaults.set(window.frame.width, forKey: PersistedWindowKeys.width(for: displayID))
        defaults.set(window.frame.height, forKey: PersistedWindowKeys.height(for: displayID))
        window.saveFrame(usingName: PersistedWindowKeys.frameAutosaveName(for: displayID))
    }

    func windowWillClose(_ notification: Notification) {
        persistCurrentWindowSize()
        unloadContent()
        NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentWindowSize()
    }

    private static func restorePersistedSize(for window: NSWindow, displayID: Int) {
        let defaults = UserDefaults.standard
        let persistedWidth = CGFloat(defaults.double(forKey: PersistedWindowKeys.width(for: displayID)))
        let persistedHeight = CGFloat(defaults.double(forKey: PersistedWindowKeys.height(for: displayID)))
        guard persistedWidth > 0, persistedHeight > 0 else { return }
        let minWidth = window.minSize.width
        let minHeight = window.minSize.height
        let maxFrame = NSScreen.main?.visibleFrame.size
        let maxWidth = maxFrame?.width ?? persistedWidth
        let maxHeight = maxFrame?.height ?? persistedHeight
        let width = min(max(persistedWidth, minWidth), maxWidth)
        let height = min(max(persistedHeight, minHeight), maxHeight)
        var frame = window.frame
        frame.size = NSSize(width: width, height: height)
        window.setFrame(frame, display: false)
    }

    private func snapToDisplayVisibleFrame() {
        guard let window else { return }
        let visibleFrame = bestVisibleFrame() ?? window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        guard !visibleFrame.isEmpty else { return }
        window.setFrame(visibleFrame, display: true, animate: false)
    }

    private func ensureContentLoaded() {
        guard let window else { return }
        if window.contentViewController is NSHostingController<AnyView> {
            return
        }
        window.contentViewController = Self.makeHostingController(model: model, displayID: displayID)
    }

    private func unloadContent() {
        guard let window else { return }
        if window.contentViewController is NSHostingController<AnyView> {
            window.contentViewController = NSViewController()
        }
    }

    private func bestVisibleFrame() -> NSRect? {
        let snapshot = model.latestLiveStateSnapshot ?? model.liveStateSnapshot
        if let display = snapshot?.displays.first(where: { $0.id == displayID }) {
            let resolved = model.megamapCaptureService.resolveScreenDescriptors(for: [display])
            if let descriptor = resolved[display.id] {
                return descriptor.visibleFrame
            }
        }

        guard let section = model.megamapDisplaySections.first(where: { $0.id == displayID }) else {
            return nil
        }
        let targetFrame = CGRect(
            x: section.desktops.first?.displayFrameX ?? 0,
            y: section.desktops.first?.displayFrameY ?? 0,
            width: section.desktops.first?.displayFrameW ?? 0,
            height: section.desktops.first?.displayFrameH ?? 0
        )
        guard !targetFrame.isEmpty else { return nil }

        var bestScreen: NSScreen?
        var bestScore: CGFloat = -.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let intersection = screen.frame.intersection(targetFrame)
            let overlapArea = intersection.isNull ? 0 : (intersection.width * intersection.height)
            let exactFrameBonus: CGFloat = screen.frame.equalTo(targetFrame) ? 2_000_000 : 0
            let exactNameBonus: CGFloat = {
                if #available(macOS 10.15, *) {
                    return screen.localizedName == section.name ? 1_000_000 : 0
                }
                return 0
            }()
            let score = overlapArea + exactFrameBonus + exactNameBonus
            if score > bestScore {
                bestScore = score
                bestScreen = screen
            }
        }
        return bestScreen?.visibleFrame
    }

    private static func makeHostingController(model: AppModel, displayID: Int) -> NSHostingController<AnyView> {
        NSHostingController(rootView: AnyView(MegamapRootView(model: model, displayID: displayID)))
    }
}

@MainActor
final class MegamapWindowController {
    private let model: AppModel
    private var displayControllers: [Int: MegamapDisplayWindowController] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func showAndFocus() {
        let displaySections = model.megamapDisplaySections
        let targetDisplayIDs = Set(displaySections.map(\.id))

        let staleDisplayIDs = displayControllers.keys.filter { !targetDisplayIDs.contains($0) }
        for displayID in staleDisplayIDs {
            displayControllers[displayID]?.hideImmediately()
            displayControllers.removeValue(forKey: displayID)
        }

        guard !displaySections.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        let primaryDisplayID = displaySections.first(where: { $0.focused })?.id ?? displaySections.first?.id

        for section in displaySections {
            let controller = displayControllers[section.id] ?? {
                let newController = MegamapDisplayWindowController(model: model, displayID: section.id)
                displayControllers[section.id] = newController
                return newController
            }()
            controller.show(makeKey: section.id == primaryDisplayID)
        }
    }

    func hideImmediately() {
        for controller in displayControllers.values {
            controller.hideImmediately()
        }
    }

    func persistCurrentWindowSize() {
        for controller in displayControllers.values {
            controller.persistCurrentWindowSize()
        }
    }
}

@MainActor
final class MegamapViewBridge: ObservableObject {
    @Published private(set) var displaySections: [MegamapDisplaySection]
    @Published private(set) var isRefreshing: Bool
    @Published private(set) var screenRecordingAuthorized: Bool
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var runtimeCommandsEnabled: Bool
    @Published private(set) var runtimeDisabledReason: String?

    let model: AppModel
    private let displayID: Int?

    private var cancellables: Set<AnyCancellable> = []

    init(model: AppModel, displayID: Int? = nil) {
        self.model = model
        self.displayID = displayID
        displaySections = Self.filterDisplaySections(model.megamapDisplaySections, for: displayID)
        isRefreshing = model.isRefreshingMegamap
        screenRecordingAuthorized = model.megamapScreenRecordingAuthorized
        lastActionMessage = model.megamapLastActionMessage
        lastErrorMessage = model.megamapLastErrorMessage
        runtimeCommandsEnabled = model.canRunYabaiRuntimeCommands
        runtimeDisabledReason = model.yabaiRuntimeControlDisabledReason

        model.$megamapDisplaySections
            .removeDuplicates()
            .sink { [weak self] in
                guard let self else { return }
                self.displaySections = Self.filterDisplaySections($0, for: self.displayID)
            }
            .store(in: &cancellables)
        model.$isRefreshingMegamap
            .removeDuplicates()
            .sink { [weak self] in self?.isRefreshing = $0 }
            .store(in: &cancellables)
        model.$megamapScreenRecordingAuthorized
            .removeDuplicates()
            .sink { [weak self] in self?.screenRecordingAuthorized = $0 }
            .store(in: &cancellables)
        model.$megamapLastActionMessage
            .removeDuplicates()
            .sink { [weak self] in self?.lastActionMessage = $0 }
            .store(in: &cancellables)
        model.$megamapLastErrorMessage
            .removeDuplicates()
            .sink { [weak self] in self?.lastErrorMessage = $0 }
            .store(in: &cancellables)
        model.$doctorSnapshot
            .sink { [weak self, weak model] _ in
                guard let self else { return }
                self.runtimeCommandsEnabled = model?.canRunYabaiRuntimeCommands ?? false
                self.runtimeDisabledReason = model?.yabaiRuntimeControlDisabledReason
            }
            .store(in: &cancellables)
    }

    func rebuildSections() {
        model.rebuildMegamapSections()
    }

    func refreshMegamap() {
        model.refreshMegamap()
    }

    func refreshDesktop(_ desktop: MegamapDesktopSection) {
        model.refreshMegamapDesktop(spaceIndex: desktop.desktopIndex)
    }

    func openScreenRecordingSettings() {
        model.openMegamapScreenRecordingSettings()
    }

    func dismissMegamap() {
        NotificationCenter.default.post(name: .tilePilotHideMegamap, object: nil)
    }

    func selectDesktop(_ desktop: MegamapDesktopSection) {
        dismissMegamap()
        let snapshot = model.latestLiveStateSnapshot ?? model.liveStateSnapshot
        let currentSpace = snapshot.flatMap { model.activeSpaceIndex(in: $0) }
        guard currentSpace != desktop.desktopIndex else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.model.focusDesktop(index: desktop.desktopIndex)
        }
    }

    func focusWindow(_ window: OverviewWindowPreview) {
        dismissMegamap()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            self.model.focusWindow(windowID: window.id, desktopIndex: window.desktopIndex)
        }
    }

    func toggleWindowFloating(_ window: OverviewWindowPreview) {
        model.toggleWindowFloating(windowID: window.id)
    }

    func setWindowFloating(_ window: OverviewWindowPreview, shouldFloat: Bool) {
        model.setWindowFloating(windowID: window.id, shouldFloat: shouldFloat)
    }

    private static func filterDisplaySections(_ sections: [MegamapDisplaySection], for displayID: Int?) -> [MegamapDisplaySection] {
        guard let displayID else { return sections }
        return sections.filter { $0.id == displayID }
    }
}

struct MegamapRootView: View {
    @StateObject private var bridge: MegamapViewBridge

    init(model: AppModel, displayID: Int? = nil) {
        _bridge = StateObject(wrappedValue: MegamapViewBridge(model: model, displayID: displayID))
    }

    var body: some View {
        MegamapDashboardView(bridge: bridge)
    }
}

private struct MegamapDashboardView: View {
    @ObservedObject var bridge: MegamapViewBridge

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.46)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        bridge.dismissMegamap()
                    }

                content(in: proxy.size)
                    .onTapGesture { }

                statusOverlay
                controlsOverlay
            }
            .background(Color.clear)
            .ignoresSafeArea()
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .animation(nil, value: bridge.displaySections)
        .animation(nil, value: bridge.isRefreshing)
        .animation(nil, value: bridge.lastActionMessage)
        .animation(nil, value: bridge.lastErrorMessage)
        .task {
            bridge.rebuildSections()
        }
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        if bridge.displaySections.isEmpty {
            emptyState
        } else {
            let fitted = fittedCompositeSize(in: size)
            VStack(spacing: 10) {
                if controlsAboveComposite {
                    inlineControls
                }
                VStack(spacing: 1) {
                    ForEach(bridge.displaySections) { display in
                        MegamapDisplayRow(display: display) { desktop in
                            bridge.selectDesktop(desktop)
                        }
                        .environmentObject(bridge)
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .clipped()

                if !controlsAboveComposite {
                    inlineControls
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Text(bridge.screenRecordingAuthorized ? "No MegaMap capture yet" : "Screen Recording is off")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(bridge.screenRecordingAuthorized ? "Use Refresh to capture all desktops." : "MegaMap is showing the synthetic fallback until macOS allows screenshots for TilePilot.")
                .font(.body)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Button("Refresh") {
                    bridge.refreshMegamap()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isRefreshing)

                if !bridge.screenRecordingAuthorized {
                    Button("Enable Screen Recording") {
                        bridge.openScreenRecordingSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func totalCompositeHeight(forWidth width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return bridge.displaySections.reduce(CGFloat.zero) { partial, display in
            let rowHeight = megamapDisplayHeight(for: display, width: width)
            let separator: CGFloat = partial == 0 ? 0 : 1
            return partial + separator + rowHeight
        }
    }

    private func fittedCompositeSize(in size: CGSize) -> CGSize {
        let maxWidth = max(size.width * 0.99, 0)
        let maxHeight = max(size.height * 0.99 - inlineControlsReservedHeight, 0)
        guard maxWidth > 0, maxHeight > 0 else { return .zero }

        var low: CGFloat = 0
        var high: CGFloat = maxWidth
        for _ in 0..<20 {
            let mid = (low + high) / 2
            let height = totalCompositeHeight(forWidth: mid)
            if height <= maxHeight {
                low = mid
            } else {
                high = mid
            }
        }

        let fittedWidth = max(low, 0)
        return CGSize(width: fittedWidth, height: totalCompositeHeight(forWidth: fittedWidth))
    }

    private func megamapDisplayHeight(for display: MegamapDisplaySection, width: CGFloat) -> CGFloat {
        let desktopAspect = max(display.desktops.first?.displayAspectRatio ?? 1.6, 0.1)
        let packing = MegamapDesktopPacking.rows(for: display.desktops)
        let maxColumns = max(MegamapDesktopPacking.maxColumns(for: packing), 1)
        let rowCount = max(packing.count, 1)
        let tileWidth = (width - CGFloat(maxColumns - 1) * MegamapDesktopPacking.gap) / CGFloat(maxColumns)
        let rowHeight = tileWidth / desktopAspect
        return (rowHeight * CGFloat(rowCount)) + (CGFloat(rowCount - 1) * MegamapDesktopPacking.gap)
    }

    private var inlineControls: some View {
        HStack(spacing: 10) {
            if !bridge.screenRecordingAuthorized {
                Button("Enable Screen Recording") {
                    bridge.openScreenRecordingSettings()
                }
                .buttonStyle(MegamapHudButtonStyle(prominent: false))
            }

            Button(bridge.isRefreshing ? "Refreshing…" : "Refresh") {
                bridge.refreshMegamap()
            }
            .buttonStyle(MegamapHudButtonStyle(prominent: true))
            .disabled(bridge.isRefreshing)
        }
    }

    private var controlsAboveComposite: Bool {
        bridge.displaySections.contains { MegamapDesktopPacking.rows(for: $0.desktops).count == 2 && MegamapDesktopPacking.maxColumns(for: MegamapDesktopPacking.rows(for: $0.desktops)) == 2 }
    }

    private var inlineControlsReservedHeight: CGFloat {
        58
    }

    private var controlsOverlay: some View {
        EmptyView()
    }

    private var statusOverlay: some View {
        VStack(spacing: 8) {
            if !bridge.screenRecordingAuthorized {
                MegamapHudNotice(
                    text: "Screen Recording is off. Showing the synthetic preview instead of real screenshots.",
                    foreground: .white,
                    background: Color.orange.opacity(0.88)
                )
            }

            if bridge.isRefreshing {
                MegamapHudNotice(
                    text: "Refreshing MegaMap…",
                    foreground: .white,
                    background: Color.blue.opacity(0.88)
                )
            } else if let error = bridge.lastErrorMessage {
                MegamapHudNotice(
                    text: error,
                    foreground: .white,
                    background: Color.red.opacity(0.88)
                )
            } else if let action = bridge.lastActionMessage {
                MegamapHudNotice(
                    text: action,
                    foreground: .white,
                    background: Color.black.opacity(0.74)
                )
            }
        }
        .padding(.top, 12)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MegamapDisplayRow: View {
    let display: MegamapDisplaySection
    let onSelect: (MegamapDesktopSection) -> Void

    var body: some View {
        let rows = MegamapDesktopPacking.rows(for: display.desktops)
        let maxColumns = max(MegamapDesktopPacking.maxColumns(for: rows), 1)

        return GeometryReader { proxy in
            let tileWidth = max(
                0,
                (proxy.size.width - (CGFloat(maxColumns - 1) * MegamapDesktopPacking.gap)) / CGFloat(maxColumns)
            )

            VStack(spacing: MegamapDesktopPacking.gap) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    HStack(spacing: MegamapDesktopPacking.gap) {
                        Spacer(minLength: 0)
                        ForEach(rows[rowIndex]) { desktop in
                            tile(for: desktop)
                                .frame(width: tileWidth)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(compositeAspectRatio, contentMode: .fit)
        .background(Color.black)
    }

    private func tile(for desktop: MegamapDesktopSection) -> some View {
        MegamapDesktopTile(desktop: desktop) {
            onSelect(desktop)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(max(desktop.displayAspectRatio, 0.1), contentMode: .fit)
    }

    private var compositeAspectRatio: CGFloat {
        let desktopAspect = max(display.desktops.first?.displayAspectRatio ?? 1.6, 0.1)
        let rows = MegamapDesktopPacking.rows(for: display.desktops)
        let maxColumns = max(MegamapDesktopPacking.maxColumns(for: rows), 1)
        let rowCount = max(rows.count, 1)
        let tileWidth = 1.0 / CGFloat(maxColumns)
        let rowHeight = tileWidth / CGFloat(desktopAspect)
        let totalHeight = (rowHeight * CGFloat(rowCount)) + ((CGFloat(rowCount - 1) * MegamapDesktopPacking.gap) / 1000.0)
        return 1.0 / totalHeight
    }
}

private enum MegamapDesktopPacking {
    static let gap: CGFloat = 1

    static func rows(for desktops: [MegamapDesktopSection]) -> [[MegamapDesktopSection]] {
        guard !desktops.isEmpty else { return [] }
        let rowCount = Int(ceil(Double(desktops.count) / 3.0))
        let baseCount = desktops.count / rowCount
        let remainder = desktops.count % rowCount

        var rows: [[MegamapDesktopSection]] = []
        rows.reserveCapacity(rowCount)

        var cursor = 0
        for rowIndex in 0..<rowCount {
            let count = baseCount + (rowIndex < remainder ? 1 : 0)
            guard count > 0 else { continue }
            let nextCursor = min(cursor + count, desktops.count)
            rows.append(Array(desktops[cursor..<nextCursor]))
            cursor = nextCursor
        }

        return rows
    }

    static func maxColumns(for rows: [[MegamapDesktopSection]]) -> Int {
        rows.map(\.count).max() ?? 1
    }
}

private struct MegamapDesktopTile: View {
    @EnvironmentObject private var bridge: MegamapViewBridge
    let desktop: MegamapDesktopSection
    let onSelect: () -> Void
    @State private var isHovered = false
    @State private var hoverOverrideMessage: String?
    private static let captureAgeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    var body: some View {
        Group {
            switch desktop.contentMode {
            case .screenshot:
                if let preview = desktop.fallbackPreview {
                    tileChrome {
                        MegamapMergedDesktopCanvas(
                            desktop: desktop,
                            preview: preview,
                            onDesktopSelect: onSelect,
                            onWindowSelect: { window in
                                bridge.focusWindow(window)
                            },
                            onWindowHoverMessageChange: { message in
                                hoverOverrideMessage = message
                            }
                        )
                    }
                } else {
                    desktopButtonTile
                }
            case .syntheticFallback:
                if let preview = desktop.fallbackPreview {
                    tileChrome {
                        MegamapSyntheticDesktopCanvas(
                            preview: preview,
                            onDesktopSelect: onSelect,
                            onWindowSelect: { window in
                                bridge.focusWindow(window)
                            },
                            onWindowHoverMessageChange: { message in
                                hoverOverrideMessage = message
                            }
                        )
                    }
                } else {
                    desktopButtonTile
                }
            case .unavailable:
                desktopButtonTile
            }
        }
    }

    private var hoverMessage: String? {
        guard isHovered else { return nil }
        return hoverOverrideMessage ?? "Jump to #\(desktop.desktopIndex)"
    }

    private var captureAgeText: String? {
        guard let capturedAt = desktop.capturedAt else { return nil }
        return Self.captureAgeFormatter.localizedString(for: capturedAt, relativeTo: Date())
    }

    private var unavailablePlaceholder: some View {
        ZStack {
            Color(white: 0.9)
            Image(systemName: "rectangle.slash")
                .font(.title2)
                .foregroundStyle(.black.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var desktopButtonTile: some View {
        tileChrome {
            switch desktop.contentMode {
            case .screenshot:
                if let screenshotPath = desktop.screenshotPath {
                    MegamapCachedScreenshotView(path: screenshotPath)
                } else {
                    unavailablePlaceholder
                }
            case .syntheticFallback:
                unavailablePlaceholder
            case .unavailable:
                unavailablePlaceholder
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private func tileChrome<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.96)
            content()

            if desktop.focused {
                Rectangle()
                    .fill(Color.blue)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .top) {
            if let message = hoverMessage {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let captureAgeText {
                Text(captureAgeText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.68), in: Capsule())
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if bridge.screenRecordingAuthorized {
                Button {
                    bridge.refreshDesktop(desktop)
                } label: {
                    Image(systemName: bridge.isRefreshing ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(Color.black.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(bridge.isRefreshing)
                .onHover { isHovering in
                    hoverOverrideMessage = isHovering ? "Refresh #\(desktop.desktopIndex)" : nil
                }
                .padding(6)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering in
            isHovered = isHovering
            if !isHovering {
                hoverOverrideMessage = nil
            }
        }
    }
}

private struct MegamapSyntheticDesktopCanvas: View {
    @EnvironmentObject private var bridge: MegamapViewBridge
    let preview: OverviewDesktopPreview
    let onDesktopSelect: () -> Void
    let onWindowSelect: (OverviewWindowPreview) -> Void
    let onWindowHoverMessageChange: (String?) -> Void
    @State private var hoveredWindowID: Int?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Color(white: 0.96)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDesktopSelect)

                ForEach(preview.windows) { window in
                    let frame = OverviewMiniMapGeometry.frame(for: window, in: size)
                    let palette = MapWindowPalette.colors(
                        windowID: window.id,
                        isFloating: window.floating,
                        usesLimitedVisualStyle: window.usesLimitedVisualStyle,
                        isFocused: window.focused,
                        preferredWarmIndex: window.warmPaletteIndex
                    )
                    let baseLineWidth: CGFloat = window.focused ? 2 : 1.2
                    let lineWidth = hoveredWindowID == window.id ? baseLineWidth * 3 : baseLineWidth
                    Rectangle()
                        .fill(Color.clear)
                        .overlay(
                            Rectangle()
                                .stroke(palette.border.opacity(window.visible ? 1 : 0.72), lineWidth: lineWidth)
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

                ForEach(preview.windows) { window in
                    let frame = OverviewMiniMapGeometry.frame(for: window, in: size)
                    let iconSize = wireframeIconDimension(for: frame.size)
                    let iconFrame = OverviewMiniMapGeometry.iconFrame(for: window, iconSize: iconSize, inset: 4, in: size)
                    let runtimeEnabled = bridge.runtimeCommandsEnabled
                    let runtimeDisabledReason = bridge.runtimeDisabledReason ?? "Unavailable"
                    let hoverTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.app : window.title
                    Button {
                        onWindowSelect(window)
                    } label: {
                        Group {
                            if let icon = AppIconResolver.shared.icon(forAppNamed: window.app, size: iconSize) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: iconFrame.width, height: iconFrame.height)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        hoveredWindowID = isHovering ? window.id : (hoveredWindowID == window.id ? nil : hoveredWindowID)
                        onWindowHoverMessageChange(isHovering ? "Jump to \"\(hoverTitle)\"" : nil)
                    }
                    .offset(x: iconFrame.minX, y: iconFrame.minY)
                    .contextMenu {
                        Button("Focus Window") {
                            bridge.focusWindow(window)
                        }
                        .disabled(!runtimeEnabled)

                        Divider()

                        Button(window.floating ? "Set Tiled" : "Set Floating") {
                            bridge.toggleWindowFloating(window)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable)

                        Button("Set Floating") {
                            bridge.setWindowFloating(window, shouldFloat: true)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable || window.floating)

                        Button("Set Tiled") {
                            bridge.setWindowFloating(window, shouldFloat: false)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable || !window.floating)

                        Divider()

                        Toggle(isOn: Binding(
                            get: { bridge.model.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating },
                            set: { enabled in
                                bridge.model.setAppForegroundPolicy(enabled ? .keepFrontWhenFloating : .useDefault, for: window.app)
                            }
                        )) {
                            Text("Keep \(window.app) on Top")
                        }

                        Toggle(isOn: Binding(
                            get: { bridge.model.isNeverAutoTileEnabled(for: window.app) },
                            set: { enabled in
                                bridge.model.setNeverAutoTileEnabled(enabled, for: window.app)
                            }
                        )) {
                            Text("Never Auto-Tile \(window.app)")
                        }

                        if !runtimeEnabled {
                            Divider()
                            Text("Unavailable: \(runtimeDisabledReason)")
                        } else if !window.runtimeManageable {
                            Divider()
                            Text("Limited: this window cannot be floated/tiled right now.")
                        }
                    }
                }
            }
        }
        .clipped()
    }

    private func wireframeIconDimension(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.72 * 1.5
        return max(18, min(40, base))
    }
}

private struct MegamapMergedDesktopCanvas: View {
    @EnvironmentObject private var bridge: MegamapViewBridge

    let desktop: MegamapDesktopSection
    let preview: OverviewDesktopPreview
    let onDesktopSelect: () -> Void
    let onWindowSelect: (OverviewWindowPreview) -> Void
    let onWindowHoverMessageChange: (String?) -> Void
    @State private var hoveredWindowID: Int?

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                desktopBackground
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDesktopSelect)

                ForEach(preview.windows) { window in
                    let frame = MegamapOverlayGeometry.frame(for: window, desktop: desktop, in: size)
                    let palette = MapWindowPalette.colors(
                        windowID: window.id,
                        isFloating: window.floating,
                        usesLimitedVisualStyle: window.usesLimitedVisualStyle,
                        isFocused: window.focused,
                        preferredWarmIndex: window.warmPaletteIndex
                    )
                    let baseLineWidth: CGFloat = window.focused ? 2 : 1.2
                    let lineWidth = hoveredWindowID == window.id ? baseLineWidth * 3 : baseLineWidth
                    Rectangle()
                        .fill(Color.clear)
                        .overlay(
                            Rectangle()
                                .stroke(palette.border.opacity(window.visible ? 1 : 0.72), lineWidth: lineWidth)
                        )
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }

                ForEach(preview.windows) { window in
                    let frame = MegamapOverlayGeometry.frame(for: window, desktop: desktop, in: size)
                    let iconSize = wireframeIconDimension(for: frame.size)
                    let iconFrame = MegamapOverlayGeometry.iconFrame(for: window, desktop: desktop, iconSize: iconSize, inset: 4, in: size)
                    let runtimeEnabled = bridge.runtimeCommandsEnabled
                    let runtimeDisabledReason = bridge.runtimeDisabledReason ?? "Unavailable"
                    let hoverTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? window.app : window.title
                    Button {
                        onWindowSelect(window)
                    } label: {
                        Group {
                            if let icon = AppIconResolver.shared.icon(forAppNamed: window.app, size: iconSize) {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .scaledToFit()
                            } else {
                                Image(systemName: "app")
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: iconFrame.width, height: iconFrame.height)
                        .opacity(window.visible ? 1 : 0.75)
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        hoveredWindowID = isHovering ? window.id : (hoveredWindowID == window.id ? nil : hoveredWindowID)
                        onWindowHoverMessageChange(isHovering ? "Jump to \"\(hoverTitle)\"" : nil)
                    }
                    .offset(x: iconFrame.minX, y: iconFrame.minY)
                    .contextMenu {
                        Button("Focus Window") {
                            bridge.focusWindow(window)
                        }
                        .disabled(!runtimeEnabled)

                        Divider()

                        Button(window.floating ? "Set Tiled" : "Set Floating") {
                            bridge.toggleWindowFloating(window)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable)

                        Button("Set Floating") {
                            bridge.setWindowFloating(window, shouldFloat: true)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable || window.floating)

                        Button("Set Tiled") {
                            bridge.setWindowFloating(window, shouldFloat: false)
                        }
                        .disabled(!runtimeEnabled || !window.runtimeManageable || !window.floating)

                        Divider()

                        Toggle(isOn: Binding(
                            get: { bridge.model.appForegroundPolicy(for: window.app) == .keepFrontWhenFloating },
                            set: { enabled in
                                bridge.model.setAppForegroundPolicy(enabled ? .keepFrontWhenFloating : .useDefault, for: window.app)
                            }
                        )) {
                            Text("Keep \(window.app) on Top")
                        }

                        Toggle(isOn: Binding(
                            get: { bridge.model.isNeverAutoTileEnabled(for: window.app) },
                            set: { enabled in
                                bridge.model.setNeverAutoTileEnabled(enabled, for: window.app)
                            }
                        )) {
                            Text("Never Auto-Tile \(window.app)")
                        }

                        if !runtimeEnabled {
                            Divider()
                            Text("Unavailable: \(runtimeDisabledReason)")
                        } else if !window.runtimeManageable {
                            Divider()
                            Text("Limited: this window cannot be floated/tiled right now.")
                        }
                    }
                }
            }
        }
        .clipped()
    }

    @ViewBuilder
    private var desktopBackground: some View {
        if let path = desktop.screenshotPath {
            MegamapCachedScreenshotView(path: path)
        } else {
            Color(white: 0.96)
        }
    }

    private func wireframeIconDimension(for size: CGSize) -> CGFloat {
        let base = min(size.width, size.height) * 0.72 * 1.5
        return max(18, min(40, base))
    }
}

private struct MegamapCachedScreenshotView: View {
    let path: String

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    Color(white: 0.96)
                }
            }
            .task(id: cacheTaskID(for: proxy.size)) {
                guard proxy.size.width > 0, proxy.size.height > 0 else { return }
                image = MegamapScreenshotCache.shared.image(for: path, idealSize: proxy.size)
            }
        }
    }

    private func cacheTaskID(for size: CGSize) -> String {
        "\(path)|\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }
}

private enum MegamapOverlayGeometry {
    static func frame(for window: OverviewWindowPreview, desktop: MegamapDesktopSection, in canvasSize: CGSize) -> CGRect {
        let displayFrame = CGRect(
            x: desktop.displayFrameX,
            y: desktop.displayFrameY,
            width: max(desktop.displayFrameW, 1),
            height: max(desktop.displayFrameH, 1)
        )
        let cropFrame = CGRect(
            x: desktop.screenshotCropX,
            y: desktop.screenshotCropY,
            width: max(desktop.screenshotCropW, 1),
            height: max(desktop.screenshotCropH, 1)
        )

        let absoluteX = displayFrame.minX + (window.normalizedX * displayFrame.width)
        let absoluteY = displayFrame.minY + (window.normalizedY * displayFrame.height)
        let absoluteW = window.normalizedW * displayFrame.width
        let absoluteH = window.normalizedH * displayFrame.height

        let croppedX = (absoluteX - cropFrame.minX) / cropFrame.width
        let croppedY = (absoluteY - cropFrame.minY) / cropFrame.height
        let croppedW = absoluteW / cropFrame.width
        let croppedH = absoluteH / cropFrame.height

        let x = max(0, min(1, croppedX)) * canvasSize.width
        let y = max(0, min(1, croppedY)) * canvasSize.height
        let maxWidth = max(0, canvasSize.width - x)
        let maxHeight = max(0, canvasSize.height - y)
        let width = min(maxWidth, max(10, croppedW * canvasSize.width))
        let height = min(maxHeight, max(8, croppedH * canvasSize.height))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func iconFrame(
        for window: OverviewWindowPreview,
        desktop: MegamapDesktopSection,
        iconSize: CGFloat,
        inset: CGFloat,
        in canvasSize: CGSize
    ) -> CGRect {
        let windowFrame = frame(for: window, desktop: desktop, in: canvasSize)
        let availableWidth = max(0, windowFrame.width - (inset * 2))
        let availableHeight = max(0, windowFrame.height - (inset * 2))
        let width = min(iconSize, availableWidth)
        let height = min(iconSize, availableHeight)
        return CGRect(
            x: windowFrame.minX + inset,
            y: windowFrame.minY + inset,
            width: width,
            height: height
        )
    }
}

private struct MegamapHudNotice: View {
    let text: String
    let foreground: Color
    let background: Color

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

private struct MegamapHudButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(background(configuration: configuration), in: RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }

    private func background(configuration: Configuration) -> some ShapeStyle {
        if prominent {
            return AnyShapeStyle(Color.blue.opacity(configuration.isPressed ? 0.82 : 0.92))
        }
        return AnyShapeStyle(Color.black.opacity(configuration.isPressed ? 0.68 : 0.78))
    }
}
