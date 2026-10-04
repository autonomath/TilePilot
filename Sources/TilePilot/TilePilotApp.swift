import AppKit
import SwiftUI

enum TilePilotTab: Hashable {
    case now
    case templates
    case workSets
    case appearance
    case windowBehavior
    case actions
    case shortcuts
    case howItWorks
    case system
    // legacy route-only cases (mapped to .system)
    case files
    case config
    case health
    case setup
    case logs

    static let visibleTabs: [TilePilotTab] = [
        .now,
        .windowBehavior,
        .actions,
        .templates,
        .workSets,
        .appearance,
        .files,
        .howItWorks,
        .system
    ]

    var title: String {
        switch self {
        case .now:
            return "Overview"
        case .appearance:
            return "Appearance"
        case .templates:
            return "Templates"
        case .workSets:
            return "Work Sets"
        case .windowBehavior:
            return "Behaviors"
        case .actions, .shortcuts:
            return "Actions & Shortcuts"
        case .howItWorks:
            return "How It Works"
        case .system, .config, .health, .setup, .logs:
            return "System"
        case .files:
            return "Config Files"
        }
    }

    var systemImage: String {
        switch self {
        case .now:
            return "rectangle.3.group"
        case .appearance:
            return "paintbrush.pointed"
        case .templates:
            return "rectangle.3.offgrid"
        case .workSets:
            return "square.stack.3d.up"
        case .windowBehavior:
            return "hand.raised.square"
        case .actions, .shortcuts:
            return "square.grid.2x2"
        case .howItWorks:
            return "questionmark.bubble"
        case .system, .config, .health, .setup, .logs:
            return "gearshape.2"
        case .files:
            return "doc.text"
        }
    }

    var canonicalVisibleTab: TilePilotTab {
        switch self {
        case .shortcuts:
            return .actions
        case .config, .health, .setup, .logs:
            return .system
        default:
            return self
        }
    }

    static func adjacentVisibleTab(
        from tab: TilePilotTab,
        moving direction: TilePilotTabNavigationDirection
    ) -> TilePilotTab {
        let canonicalTab = tab.canonicalVisibleTab
        guard let currentIndex = visibleTabs.firstIndex(of: canonicalTab) else {
            return visibleTabs.first ?? .now
        }

        switch direction {
        case .previous:
            return visibleTabs[max(visibleTabs.startIndex, currentIndex - 1)]
        case .next:
            return visibleTabs[min(visibleTabs.index(before: visibleTabs.endIndex), currentIndex + 1)]
        }
    }
}

enum TilePilotTabNavigationDirection {
    case previous
    case next
}

@main
struct TilePilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Settings {
            SettingsPlaceholderView()
                .environmentObject(model)
        }
    }
}

struct TilePilotRootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: TilePilotTab = .now
    @State private var hasAppliedInitialTabSelection = false

    private var showSetupGuideBinding: Binding<Bool> {
        Binding(
            get: { model.setupGuidePresentationState.isPresented },
            set: { isPresented in
                if !isPresented {
                    model.dismissSetupGuide()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            selectedTabContent
        }
        .frame(minWidth: 1120, minHeight: 720)
        .environment(\.controlActiveState, .key)
        .onChange(of: model.requestedTilePilotTab) { newValue in
            if let newValue {
                selectedTab = newValue.canonicalVisibleTab
                model.currentVisibleTab = selectedTab
                model.publishLatestLiveStateForCurrentTab(force: true)
                _ = model.consumeRequestedTilePilotTab()
            }
        }
        .onChange(of: selectedTab) { newValue in
            if newValue != .appearance {
                NSColorPanel.shared.orderOut(nil)
            }
            model.currentVisibleTab = newValue
            model.publishLatestLiveStateForCurrentTab(force: true)
        }
        .task {
            if !hasAppliedInitialTabSelection {
                selectedTab = (model.consumeShouldStartOnSetupTab() ? TilePilotTab.system : model.currentVisibleTab).canonicalVisibleTab
                hasAppliedInitialTabSelection = true
            }
            model.currentVisibleTab = selectedTab
            model.publishLatestLiveStateForCurrentTab(force: true)
            model.startIfNeeded()
            if model.doctorSnapshot == nil {
                await model.refreshDoctor()
            }
        }
        .sheet(isPresented: showSetupGuideBinding) {
            SetupGuideView()
                .environmentObject(model)
        }
    }

    private var tabBar: some View {
        TilePilotTabStrip(selection: $selectedTab)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var selectedTabContent: some View {
        switch selectedTab.canonicalVisibleTab {
        case .now:
            NowDashboardView()
        case .windowBehavior:
            WindowBehaviorDashboardView()
        case .actions, .shortcuts:
            UnifiedControlsDashboardView()
        case .templates:
            TemplatesDashboardView()
        case .workSets:
            WorkSetsDashboardView()
        case .appearance:
            AppearanceDashboardView()
        case .files:
            FilesDashboardView()
        case .howItWorks:
            HowItWorksDashboardView()
        case .system, .config, .health, .setup, .logs:
            SystemDashboardView()
        }
    }
}

struct TilePilotTabStrip: View {
    static let maximumWidth: CGFloat = 1080
    static let height: CGFloat = 20

    @Binding var selection: TilePilotTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(TilePilotTab.visibleTabs.enumerated()), id: \.element) { index, tab in
                if index > TilePilotTab.visibleTabs.startIndex {
                    Rectangle()
                        .fill(Color(NSColor.separatorColor).opacity(0.75))
                        .frame(width: 1, height: 12)
                        .accessibilityHidden(true)
                }

                tabButton(for: tab)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: Self.height)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.55), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("TilePilot Sections")
        .frame(maxWidth: Self.maximumWidth)
    }

    private func tabButton(for tab: TilePilotTab) -> some View {
        let isSelected = selection.canonicalVisibleTab == tab

        return Button {
            selection = tab
        } label: {
            Text(tab.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .allowsTightening(true)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: Self.height, maxHeight: Self.height)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(NSColor.controlAccentColor))
            }
        }
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("TilePilot.Tab.\(tab.title)")
        .onMoveCommand { direction in
            switch direction {
            case .left:
                selection = TilePilotTab.adjacentVisibleTab(from: selection, moving: .previous)
            case .right:
                selection = TilePilotTab.adjacentVisibleTab(from: selection, moving: .next)
            default:
                break
            }
        }
    }
}

struct UnifiedControlsDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ShortcutsDashboardView()
    }
}
