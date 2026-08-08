import SwiftUI
import UIKit

/// Permissions (§52).
///
/// Reading each permission's state and saying, in one sentence, exactly what stops working without
/// it. A denied permission is not an error state here — it is a documented trade the user made, and
/// this screen respects that rather than nagging.
@MainActor
struct PermissionsSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.openURL) private var openURL

    @State private var statuses: [AuraPermission: PermissionStatus] = [:]

    var body: some View {
        List {
            Section {
                ForEach(AuraPermission.allCases) { permission in
                    PermissionRow(
                        permission: permission,
                        status: statuses[permission] ?? .notDetermined,
                        assistantName: environment.assistantName,
                        onRequest: { request(permission) },
                        onOpenSettings: openSystemSettings
                    )
                }
            } footer: {
                Text("I ask for each of these the first time something needs it, and explain why before the system prompt appears.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Permissions")
        .task { await reload() }
    }

    private func reload() async {
        statuses = await environment.permissionManager.allStatuses()
    }

    private func request(_ permission: AuraPermission) {
        Task {
            _ = await environment.permissionManager.request(permission)
            await reload()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}

@MainActor
private struct PermissionRow: View {
    let permission: AuraPermission
    let status: PermissionStatus
    let assistantName: String
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: permission.symbolName)
                    .frame(width: 24)
                    .foregroundStyle(status.isUsable ? Color.green : Color.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(permission.displayName)
                    Text("\(assistantName) uses this \(permission.rationale)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !status.isUsable {
                        Text(permission.degradationNotice)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Text(status.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch status {
            case .notDetermined:
                Button("Allow", action: onRequest)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .denied, .limited:
                // iOS shows no prompt the second time, so the only honest action is to send the user
                // where the switch actually lives.
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .restricted:
                Text("Blocked by device restrictions.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            case .authorized:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        PermissionsSettingsView()
    }
    .environment(AppEnvironment.preview())
}
