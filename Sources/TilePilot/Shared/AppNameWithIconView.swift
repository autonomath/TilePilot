import SwiftUI

struct AppNameWithIconView: View {
    let appName: String

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppIconResolver.shared.icon(forAppNamed: appName, size: 16) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "app")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }
            Text(appName)
        }
    }
}
