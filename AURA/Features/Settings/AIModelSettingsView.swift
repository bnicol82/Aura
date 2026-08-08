import SwiftUI

/// AI mode and provider status (§7, §46, §50).
///
/// Two things this screen must never do: describe cloud processing vaguely, and show a provider as
/// available when it is not. Each mode states plainly where data goes, and each provider row shows its
/// live availability and the reason when it cannot be used.
@MainActor
struct AIModelSettingsView: View {
    @Environment(AppEnvironment.self) private var environment


    var body: some View {
        Form {
            Section {
                ForEach(AIMode.allCases) { mode in
                    Button {
                        var mutation = AssistantProfileMutation()
                        mutation.aiMode = mode
                        Task { await environment.update(mutation) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbolName(for: mode))
                                .frame(width: 24)
                                .foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.displayName)
                                    .foregroundStyle(.primary)
                                Text(mode.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if environment.assistantProfile.aiMode == mode {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Where I think")
            } footer: {
                Text("Whatever you pick, deciding what's worth remembering always happens on this iPhone — that step never goes to a cloud provider.")
            }

            Section {
                if environment.providerStates.isEmpty {
                    // Only before the first availability check completes; it is not a stub state.
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("Checking what's available…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(environment.providerStates) { state in
                        ProviderStatusRow(state: state)
                    }
                }
            } header: {
                Text("Models")
            }

            if environment.assistantProfile.aiMode.allowsCloudProviders {
                Section {
                    Label(
                        "I only send what a request actually needs — never your whole memory.",
                        systemImage: "hand.raised"
                    )
                    .font(.footnote)
                } header: {
                    Text("When I use a cloud model")
                }
            }
        }
        .navigationTitle("AI Model")
        .task {
            // Availability changes outside the app — Apple Intelligence gets switched on, assets finish
            // downloading — so this screen always asks fresh rather than trusting the launch-time read.
            await environment.refreshProviderStates()
        }
    }

    private func symbolName(for mode: AIMode) -> String {
        switch mode {
        case .onDeviceOnly: return "iphone"
        case .automatic: return "wand.and.stars"
        case .cloudEnhanced: return "cloud"
        }
    }
}

@MainActor
private struct ProviderStatusRow: View {
    let state: ProviderState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.isOnDevice ? "iphone" : "cloud")
                .frame(width: 24)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.displayName)
                    if state.isActiveDefault {
                        Text("In use")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.15), in: Capsule())
                    }
                }
                Text(state.availability.userFacingDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = state.availability.userFacingRecovery {
                    Text(recovery)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: state.availability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(state.availability.isAvailable ? Color.green : Color.orange)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        AIModelSettingsView()
    }
    .environment(AppEnvironment.preview())
}
