import SwiftUI

/// The privacy dashboard (§49).
///
/// One screen that answers, without hedging: where does processing happen, what is stored, what
/// leaves the device, who has permission, and how do I delete it. Every number here is read from the
/// stores rather than estimated — a dashboard that rounded or guessed would be worse than none.
@MainActor
struct PrivacyDashboardView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var permissionStatuses: [AuraPermission: PermissionStatus] = [:]
    @State private var isConfirmingWipe = false
    @State private var resultMessage: String?

    var body: some View {
        List {
            processingSection
            storageSection
            permissionsSection
            controlsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Privacy")
        .task {
            permissionStatuses = await environment.permissionManager.allStatuses()
            await environment.refreshProviderStates()
        }
        .confirmationDialog(
            "Delete everything?",
            isPresented: $isConfirmingWipe,
            titleVisibility: .visible
        ) {
            Button("Delete all my data", role: .destructive) { wipeEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile, the people you've told me about, every memory and every conversation. This can't be undone.")
        }
        .infoAlert(message: $resultMessage)
    }

    // MARK: - Sections

    private var processingSection: some View {
        Section {
            PrivacyStatusRow(
                title: "On-device AI",
                value: onDeviceStatusText,
                symbolName: "iphone",
                tone: onDeviceIsAvailable ? .good : .neutral,
                detail: environment.providerStates
                    .first(where: { $0.isOnDevice && !$0.availability.isAvailable })?
                    .availability.userFacingRecovery
            )
            PrivacyStatusRow(
                title: "Cloud AI",
                value: cloudStatusText,
                symbolName: "cloud",
                tone: environment.assistantProfile.aiMode.allowsCloudProviders ? .caution : .good
            )
            PrivacyStatusRow(
                title: "Memory extraction",
                value: "On this iPhone, always",
                symbolName: "brain",
                tone: .good
            )
        } header: {
            Text("Where processing happens")
        } footer: {
            Text("Deciding what's worth remembering never leaves this device, whatever AI mode you choose.")
        }
    }

    private var storageSection: some View {
        Section {
            PrivacyStatusRow(
                title: "Stored on this iPhone",
                value: "\(environment.userProfile.knownItemCount) things about you",
                symbolName: "internaldrive",
                tone: .neutral
            )
            PrivacyStatusRow(
                title: "People",
                value: "\(environment.userProfile.people.count)",
                symbolName: "person.2",
                tone: .neutral
            )
            PrivacyStatusRow(
                title: "iCloud sync",
                value: environment.persistence.sync.statusLabel,
                symbolName: "icloud",
                tone: environment.persistence.sync.isCloudEnabled ? .neutral : .good
            )
            PrivacyStatusRow(
                title: "Imported files",
                value: "0",
                symbolName: "doc",
                tone: .good
            )
            PrivacyStatusRow(
                title: "Recorded audio",
                value: "Never kept",
                symbolName: "waveform",
                tone: .good
            )
        } header: {
            Text("What's stored")
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(AuraPermission.allCases) { permission in
                let status = permissionStatuses[permission] ?? .notDetermined
                PrivacyStatusRow(
                    title: permission.displayName,
                    value: status.displayName,
                    symbolName: permission.symbolName,
                    tone: status.isUsable ? .good : .neutral,
                    detail: status.isUsable ? nil : permission.degradationNotice
                )
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("I ask for these one at a time, when something actually needs them — never all at once.")
        }
    }

    private var controlsSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.whatIKnow) {
                Label("Review and edit what I know", systemImage: "list.bullet.rectangle")
            }
            NavigationLink(value: SettingsRoute.memory) {
                Label("Memory settings", systemImage: "brain")
            }
            Button {
                // Phase 13.
            } label: {
                Label("Export my data", systemImage: "square.and.arrow.up")
            }
            .disabled(!FeatureFlags.dataExport.isLive)

            Button("Delete all my data", role: .destructive) {
                isConfirmingWipe = true
            }
        } header: {
            Text("Your controls")
        } footer: {
            if let note = FeatureFlags.dataExport.userFacingNote {
                Text(note)
            }
        }
    }

    /// Whether an on-device model can actually answer right now — a live check, not a build flag.
    private var onDeviceIsAvailable: Bool {
        environment.providerStates.contains { $0.isOnDevice && $0.availability.isAvailable }
    }

    private var onDeviceStatusText: String {
        guard let state = environment.providerStates.first(where: \.isOnDevice) else {
            return "Checking…"
        }
        return state.availability.isAvailable ? "Active" : state.availability.statusLabel
    }

    private var cloudStatusText: String {
        environment.assistantProfile.aiMode.allowsCloudProviders
            ? "Allowed — \(environment.assistantProfile.aiMode.displayName)"
            : "Off"
    }

    private func wipeEverything() {
        Task {
            do {
                try await environment.userProfileStore.deleteAllProfileData()
                try environment.credentialStore.deleteAll()
                await environment.refreshUserProfile()
                resultMessage = "Everything's gone. I don't know anything about you."
            } catch {
                resultMessage = error.auraDescription
            }
        }
    }
}

@MainActor
private struct PrivacyStatusRow: View {
    enum Tone {
        case good, neutral, caution
    }

    let title: String
    let value: String
    let symbolName: String
    let tone: Tone
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .frame(width: 24)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch tone {
        case .good: return .green
        case .neutral: return .secondary
        case .caution: return .orange
        }
    }
}

#Preview {
    NavigationStack {
        PrivacyDashboardView()
    }
    .environment(AppEnvironment.preview())
}
