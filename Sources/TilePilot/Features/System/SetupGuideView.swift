import SwiftUI

struct SetupGuideView: View {
    @EnvironmentObject private var model: AppModel

    private var steps: [SetupGuideStep] {
        model.setupGuideSteps
    }

    private var currentStep: SetupGuideStep? {
        model.currentSetupGuideStep
    }

    private var hasRemainingIncompleteSteps: Bool {
        !model.incompleteSetupGuideSteps.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if let welcomePage = model.setupGuideWelcomePage {
                    welcomeTour(welcomePage)
                } else {
                    checklistBody
                }
            }
            .frame(minWidth: 980, idealWidth: 1080, minHeight: 640, idealHeight: 720)
            .navigationTitle("Guided Setup")
            .confirmationDialog(
                model.helperMigrationPrompt?.title ?? "Existing Helper Install Detected",
                isPresented: Binding(
                    get: { model.helperMigrationPrompt != nil },
                    set: { isPresented in
                        if !isPresented {
                            model.dismissHelperMigrationPrompt()
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Use Existing Install") {
                    model.keepExistingHelperInstall()
                }
                Button("Replace With TilePilot Components", role: .destructive) {
                    model.replaceWithManagedHelpers()
                }
                Button("Cancel", role: .cancel) {
                    model.dismissHelperMigrationPrompt()
                }
            } message: {
                Text(model.helperMigrationPrompt?.message ?? "")
            }
        }
    }

    private var checklistBody: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if let step = currentStep {
                HStack(alignment: .top, spacing: 18) {
                    stepList
                        .frame(width: 250)
                    stepDetail(step)
                }
            } else {
                completionState
            }
        }
        .padding(20)
    }

    // MARK: - First-launch feature tour

    private func welcomeTour(_ page: SetupGuideWelcomePage) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: page.symbolName)
                        .font(.system(size: 44, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(height: 56)

                    VStack(spacing: 10) {
                        Text(page.title)
                            .font(.largeTitle.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(page.subtitle)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 640)
                    }

                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                        ForEach(page.highlights) { highlight in
                            welcomeHighlightCard(highlight)
                        }
                    }
                    .frame(maxWidth: 760)

                    if let banner = welcomePermissionBanner(for: page) {
                        banner
                            .frame(maxWidth: 760)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }

            Divider()

            welcomeTourControls(page)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
        }
    }

    private func welcomeHighlightCard(_ highlight: SetupGuideWelcomePage.FeatureHighlight) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: highlight.symbolName)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(highlight.title)
                    .font(.subheadline.weight(.semibold))
                Text(highlight.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func welcomePermissionBanner(for page: SetupGuideWelcomePage) -> AnyView? {
        switch page.permission {
        case .none:
            guard let explanation = page.permissionExplanation else { return nil }
            return AnyView(
                permissionBanner(
                    symbol: "hand.raised",
                    tint: .secondary,
                    label: "No new permission on this screen",
                    explanation: explanation
                )
            )
        case .required(let name):
            return AnyView(
                permissionBanner(
                    symbol: "lock.open",
                    tint: Color.orange,
                    label: "Needs: \(name)",
                    explanation: page.permissionExplanation ?? ""
                )
            )
        case .optional(let name):
            return AnyView(
                permissionBanner(
                    symbol: "lock",
                    tint: Color.blue,
                    label: "Optional: \(name)",
                    explanation: page.permissionExplanation ?? ""
                )
            )
        }
    }

    private func permissionBanner(symbol: String, tint: Color, label: String, explanation: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)
                if !explanation.isEmpty {
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func welcomeTourControls(_ page: SetupGuideWelcomePage) -> some View {
        let pages = SetupGuideWelcomeContent.pages
        let currentIndex = pages.firstIndex(of: page) ?? 0

        return HStack(spacing: 12) {
            Button("Skip Tour") {
                model.finishSetupGuideWelcomeTour()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 7) {
                ForEach(0..<pages.count, id: \.self) { index in
                    Circle()
                        .fill(index == currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if currentIndex > 0 {
                    Button("Back") {
                        model.rewindSetupGuideWelcomePage()
                    }
                    .buttonStyle(.bordered)
                }

                Button(model.setupGuideWelcomeIsLastPage ? "Start Setup" : "Continue") {
                    model.advanceSetupGuideWelcomePage()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Checklist

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(model.setupGuideCompletionTitle)
                    .font(.title2.weight(.semibold))
                Spacer()
                checklistProgressLabel
            }
            Text(model.setupGuideCompletionDetail)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.lastErrorMessage {
                statusMessage(text: error, color: .red)
            } else if let message = model.lastActionMessage {
                statusMessage(text: message, color: .green)
            }
        }
    }

    private var checklistProgressLabel: some View {
        let total = steps.count
        let done = steps.filter(\.isSatisfied).count
        return Text("\(done) of \(total) complete")
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private var stepList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Steps")
                .font(.headline)

            ForEach(steps) { step in
                Button {
                    model.selectSetupGuideStep(step.kind)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: step.status.symbolName)
                            .foregroundStyle(color(for: step.status))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Text(step.category.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectionBackground(for: step), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            Button {
                model.replaySetupGuideWelcomeTour()
            } label: {
                Label("Replay Feature Tour", systemImage: "play.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
        }
    }

    private func stepDetail(_ step: SetupGuideStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                stepDetailContent(step)
                    .padding(.trailing, 8)
            }

            Divider()

            actionBar(for: step)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func stepDetailContent(_ step: SetupGuideStep) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(step.category.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: step.status))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color(for: step.status).opacity(0.12), in: Capsule())

                Text(statusLabel(for: step))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(step.status == .good ? .green : .secondary)
            }

            wrappingText(step.title, font: .title3.weight(.semibold), style: .primary)
            wrappingText(step.summary, font: .body, style: .primary)

            if step.kind == .installHelpers || step.kind == .startHelperServices {
                windowControlExplainer
            }

            if step.kind == .missionControl {
                missionControlDetail(step)
            } else if step.isSatisfied {
                if let detail = step.detail, !detail.isEmpty {
                    detailSection(title: "Current status", detail)
                }
            } else {
                nextStepDetail(step)
            }

            if step.kind != .installHelpers && step.kind != .startHelperServices {
                detailSection(title: step.category == .featureOptional ? "What this enables" : "Why TilePilot needs this", step.whyItMatters)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func missionControlDetail(_ step: SetupGuideStep) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Checklist")
                    .font(.headline)
                wrappingText(step.whatToDo, font: .body, style: .primary)
                MissionControlChecklistView(items: model.missionControlChecklistItems)
                if let detail = step.detail, !detail.isEmpty {
                    Divider()
                    wrappingText(detail, font: .callout, style: .secondary)
                }
                if let verificationText = step.verificationText, !verificationText.isEmpty {
                    Divider()
                    wrappingText(verificationText, font: .callout, style: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func nextStepDetail(_ step: SetupGuideStep) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("What to do next")
                    .font(.headline)
                wrappingText(step.whatToDo, font: .body, style: .primary)
                if let detail = step.detail, !detail.isEmpty {
                    Divider()
                    wrappingText(detail, font: .callout, style: .secondary)
                }
                if let verificationText = step.verificationText, !verificationText.isEmpty {
                    Divider()
                    wrappingText(verificationText, font: .callout, style: .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionBar(for step: SetupGuideStep) -> some View {
        HStack(spacing: 10) {
            if let primaryAction = step.primaryAction, !step.isSatisfied {
                Button(primaryButtonLabel(for: step, action: primaryAction)) {
                    if step.kind == .startHelperServices, primaryAction == .startYabai || primaryAction == .startSkhd {
                        model.startWindowControlBestEffort()
                    } else {
                        model.performSystemCheckAction(primaryAction)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryActionInFlight(for: step))
            } else {
                Button(hasRemainingIncompleteSteps ? "Continue" : "Done") {
                    if hasRemainingIncompleteSteps {
                        model.continueSetupGuide()
                    } else {
                        model.dismissSetupGuide()
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            ForEach(step.displayedSecondaryActions, id: \.self) { action in
                Button(secondaryButtonLabel(for: action)) {
                    model.performSystemCheckAction(action)
                }
                .buttonStyle(.bordered)
                .disabled(secondaryActionInFlight(action))
            }

            Spacer()

            if hasRemainingIncompleteSteps, step.isSkippable || step.isBlocking {
                Button("Skip for Now") {
                    model.dismissSetupGuide()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func detailSection(title: String, _ body: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                wrappingText(body, font: .body, style: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var windowControlExplainer: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("What are yabai and skhd?")
                    .font(.headline)
                wrappingText("yabai reads and moves windows/desktops. skhd listens for global keyboard shortcuts. TilePilot installs its own local copies under your user account and starts them as user LaunchAgents.", font: .body, style: .secondary)
                wrappingText("If macOS asks for Accessibility access, approve only the exact TilePilot, yabai, or skhd entry macOS names, then come back to TilePilot.", font: .body, style: .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var completionState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("TilePilot is ready")
                .font(.title3.weight(.semibold))
            Text("All required setup is complete. You can reopen Guided Setup later from System or the menu bar if you want to review optional permissions again.")
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Continue") {
                    model.dismissSetupGuide()
                }
                .buttonStyle(.borderedProminent)

                Button("Review Steps") {
                    if let first = steps.first {
                        model.selectSetupGuideStep(first.kind)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func selectionBackground(for step: SetupGuideStep) -> some ShapeStyle {
        if currentStep?.kind == step.kind {
            return AnyShapeStyle(Color.accentColor.opacity(0.14))
        }
        return AnyShapeStyle(Color.secondary.opacity(0.08))
    }

    private func statusMessage(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func wrappingText(_ text: String, font: Font, style: HierarchicalShapeStyle) -> some View {
        Text(text)
            .font(font)
            .foregroundStyle(style)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func color(for status: SystemCheckStatus) -> Color {
        switch status {
        case .good:
            return .green
        case .notice:
            return .yellow
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private func statusLabel(for step: SetupGuideStep) -> String {
        if step.status == .good {
            return "Complete"
        }
        if step.category == .featureOptional {
            return "Optional"
        }
        return "Needs attention"
    }

    private func primaryButtonLabel(for step: SetupGuideStep, action: SystemCheckAction) -> String {
        switch (step.kind, action) {
        case (.installHelpers, .installDependencies):
            return "Retry Component Install"
        case (.startHelperServices, .startYabai), (.startHelperServices, .startSkhd):
            return "Start Window Control"
        case (.accessibility, .requestAccessibilityAccess):
            return "Request Accessibility Access"
        case (.startAtLogon, .enableStartAtLogon):
            return "Enable Start at Login"
        case (.missionControl, .openMissionControlSettings):
            return "Open Mission Control Settings"
        case (.screenRecording, .requestScreenRecordingAccess):
            return "Enable Screen Recording"
        default:
            return action.label
        }
    }

    private func secondaryButtonLabel(for action: SystemCheckAction) -> String {
        switch action {
        case .openAccessibilitySettings:
            return "Open Accessibility Settings"
        case .openLoginItemsSettings:
            return "Open Login Items"
        case .openMissionControlSettings:
            return "Open Mission Control Settings"
        case .openMissionControlKeyboardShortcuts:
            return "Open Keyboard Shortcuts"
        case .openScreenRecordingSettings:
            return "Open Screen Recording Settings"
        default:
            return action.label
        }
    }

    private func primaryActionInFlight(for step: SetupGuideStep) -> Bool {
        switch step.kind {
        case .installHelpers, .startHelperServices:
            return model.isLaunchingSetupInstaller
        case .accessibility, .screenRecording:
            return false
        case .startAtLogon, .missionControl:
            return false
        }
    }

    private func secondaryActionInFlight(_ action: SystemCheckAction) -> Bool {
        switch action {
        case .recheck:
            return model.isRefreshing || model.isRefreshingBootstrap
        case .installDependencies, .startYabai, .startSkhd, .restartYabai, .restartSkhd:
            return model.isLaunchingSetupInstaller
        default:
            return false
        }
    }
}
