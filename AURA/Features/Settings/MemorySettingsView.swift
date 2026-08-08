import SwiftUI

/// Memory settings (§48).
@MainActor
struct MemorySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var isConfirmingClearMemory = false
    @State private var isConfirmingClearProfile = false
    @State private var resultMessage: String?

    var body: some View {
        Form {
            Section {
                Toggle("Remember useful things automatically", isOn: automaticMemoryBinding)
                Toggle("Ask before saving", isOn: asksBeforeSavingBinding)
                    .disabled(!environment.assistantProfile.memory.automaticMemoryEnabled)
                Toggle("Use what you remember in answers", isOn: usesMemoryBinding)
            } header: {
                Text("Memory")
            } footer: {
                Text(memoryFooter)
            }

            Section {
                Toggle("Sync with iCloud", isOn: cloudSyncBinding)
                    .disabled(!FeatureFlags.cloudSync.isLive)
                if !FeatureFlags.cloudSync.isLive {
                    PendingFeatureNotice(stage: FeatureFlags.cloudSync, symbolName: "icloud")
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                }
            } header: {
                Text("iCloud")
            }

            Section {
                NavigationLink(value: SettingsRoute.whatIKnow) {
                    Label("Review what I know", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Review")
            }

            Section {
                Button("Clear everything I know about you", role: .destructive) {
                    isConfirmingClearProfile = true
                }
                Button("Clear all memories", role: .destructive) {
                    isConfirmingClearMemory = true
                }
                .disabled(!FeatureFlags.memory.isLive)
            } header: {
                Text("Delete")
            } footer: {
                Text("Deleting is immediate and can't be undone. If you ask me to forget something, it's really gone.")
            }
        }
        .navigationTitle("Memory")
        .confirmationDialog(
            "Clear everything you've told me?",
            isPresented: $isConfirmingClearProfile,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive) { clearProfile() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your name, the people you've told me about, your interests, goals and routines. \(environment.userProfile.knownItemCount) things in all.")
        }
        .confirmationDialog(
            "Clear all memories?",
            isPresented: $isConfirmingClearMemory,
            titleVisibility: .visible
        ) {
            Button("Delete all memories", role: .destructive) {}
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything I've picked up from our conversations.")
        }
        .infoAlert(message: $resultMessage)
    }

    private var memoryFooter: String {
        let memory = environment.assistantProfile.memory
        if !memory.automaticMemoryEnabled {
            return "I won't learn anything on my own. You can still tell me to remember something, and edit what I know by hand."
        }
        if memory.asksBeforeSaving {
            return "I'll suggest things to remember and wait for your yes before keeping any of them."
        }
        return "I'll keep the things that look genuinely useful — preferences, people, decisions, commitments — and skip the small talk."
    }

    // MARK: - Bindings

    private var automaticMemoryBinding: Binding<Bool> {
        Binding(
            get: { environment.assistantProfile.memory.automaticMemoryEnabled },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.automaticMemoryEnabled = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    private var asksBeforeSavingBinding: Binding<Bool> {
        Binding(
            get: { environment.assistantProfile.memory.asksBeforeSaving },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.asksBeforeSaving = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    private var usesMemoryBinding: Binding<Bool> {
        Binding(
            get: { environment.assistantProfile.memory.usesMemoryInResponses },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.usesMemoryInResponses = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    private var cloudSyncBinding: Binding<Bool> {
        Binding(
            get: { environment.assistantProfile.memory.cloudSyncEnabled },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.cloudSyncEnabled = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    // MARK: - Actions

    private func clearProfile() {
        Task {
            do {
                try await environment.userProfileStore.deleteAllProfileData()
                await environment.refreshUserProfile()
                resultMessage = "Cleared. I don't know anything about you now."
            } catch {
                resultMessage = error.auraDescription
            }
        }
    }
}

#Preview {
    NavigationStack {
        MemorySettingsView()
    }
    .environment(AppEnvironment.preview())
}
