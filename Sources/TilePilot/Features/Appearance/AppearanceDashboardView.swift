import SwiftUI

struct AppearanceDashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    overlaysCard
                    spacingCard
                }
                .padding()
            }
            .navigationTitle("TilePilot")
            .task { await model.refreshWindowBehaviorConfig() }
        }
    }

    private var overlaysCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("These controls affect TilePilot's desktop overlays only. MegaMap and mini-map wireframes are unchanged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Window Badges", isOn: Binding(
                    get: { model.showWindowBadgeOverlay },
                    set: { model.setWindowBadgeOverlayEnabled($0) }
                ))

                Toggle("Window Outline Overlay", isOn: Binding(
                    get: { model.showWindowOutlineOverlay },
                    set: { model.setWindowOutlineOverlayEnabled($0) }
                ))

                AppearanceIntegerControl(
                    title: "Outline Width",
                    unit: "px",
                    value: Binding(
                        get: { Int(model.windowOutlineOverlayBaseWidth.rounded()) },
                        set: { model.setWindowOutlineOverlayBaseWidth(Double($0)) }
                    ),
                    range: 1 ... 6,
                    isDisabled: !model.showWindowOutlineOverlay
                )

                AppearanceColorControl(
                    title: "Tiled Windows",
                    selection: Binding(
                        get: { model.tiledOverlayAccentColor.swiftUIColor },
                        set: { newColor in
                            if let converted = OverlayAccentColor.from(swiftUIColor: newColor) {
                                model.setTiledOverlayAccentColor(converted)
                            }
                        }
                    ),
                    isDisabled: !model.showWindowBadgeOverlay && !model.showWindowOutlineOverlay
                )

                AppearanceColorControl(
                    title: "Floating Windows",
                    selection: Binding(
                        get: { model.floatingOverlayAccentColor.swiftUIColor },
                        set: { newColor in
                            if let converted = OverlayAccentColor.from(swiftUIColor: newColor) {
                                model.setFloatingOverlayAccentColor(converted)
                            }
                        }
                    ),
                    isDisabled: !model.showWindowBadgeOverlay && !model.showWindowOutlineOverlay
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Overlays", systemImage: "square.stack.3d.up")
        }
    }

    private var spacingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Global yabai tiling layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                AppearanceIntegerControl(
                    title: "Screen Edge Padding",
                    unit: "pt",
                    value: Binding(
                        get: { model.windowBehaviorPolicyDraft.outerPadding },
                        set: { model.updateOuterPaddingDraft($0) }
                    ),
                    range: 0 ... 100,
                    isDisabled: false
                )

                AppearanceIntegerControl(
                    title: "Gap Between Tiled Windows",
                    unit: "pt",
                    value: Binding(
                        get: { model.windowBehaviorPolicyDraft.windowGap },
                        set: { model.updateWindowGapDraft($0) }
                    ),
                    range: 0 ... 100,
                    isDisabled: false
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Tiling Layout", systemImage: "rectangle.split.3x1")
        }
    }
}

private struct AppearanceColorControl: View {
    let title: String
    @Binding var selection: Color
    let isDisabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)

            ColorPicker("", selection: $selection, supportsOpacity: false)
                .labelsHidden()
                .disabled(isDisabled)

            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selection)
                .frame(width: 28, height: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )

            Spacer(minLength: 0)
        }
    }
}

private struct AppearanceIntegerControl: View {
    let title: String
    let unit: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let isDisabled: Bool

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 0
        formatter.maximum = 100
        return formatter
    }()

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)

            TextField("0", value: $value, formatter: Self.formatter)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .disabled(isDisabled)

            Text(unit)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Stepper("", value: $value, in: range)
                .labelsHidden()
                .controlSize(.small)
                .disabled(isDisabled)

            Spacer(minLength: 0)
        }
    }
}
