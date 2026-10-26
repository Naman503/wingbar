import SwiftUI

struct OnboardingView: View {
    @ObservedObject var permissions: Permissions
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "chevron.left.2")
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Wingbar").font(.title2.bold())
                    Text("Take back the menu bar icons hiding behind the notch.")
                        .foregroundStyle(.secondary)
                }
            }

            PermissionRows(permissions: permissions)

            VStack(alignment: .leading, spacing: 8) {
                Text("How it works").font(.headline)
                Label("Wingbar adds its icon and a thin divider line next to Control Centre.", systemImage: "chevron.left.2")
                Label("Hold ⌘ and drag the icons you always want to see to the right of the line. Everything left of it can be hidden.", systemImage: "command")
                Label("Click the Wingbar icon to hide or show that section. Nothing is hidden until you do.", systemImage: "cursorarrow.click")
                Label("Right-click it to open any hidden icon, even one under the notch.", systemImage: "list.bullet")
            }
            .font(.callout)
            .labelStyle(OnboardingLabelStyle())

            HStack {
                if !permissions.accessibility {
                    Text("Without Accessibility, Wingbar can only hide and show items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(permissions.accessibility ? "Done" : "Continue Without", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }
}

private struct OnboardingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon.foregroundStyle(.secondary).frame(width: 18)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
