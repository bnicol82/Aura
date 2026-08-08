import SwiftUI

/// Renaming the assistant (§9, §47).
///
/// The name is not decoration: it appears in the tab bar, in navigation titles, in every greeting,
/// and in the first line of every prompt the model sees. Nothing in the app hard-codes "AURA".
@MainActor
struct AssistantSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var name = ""
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section {
                TextField("Assistant name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commit)
            } header: {
                Text("Name")
            } footer: {
                Text("Up to \(AuraDefaults.assistantNameMaxLength) characters. This is what I'll answer to everywhere.")
            }

            Section("Suggestions") {
                ForEach(AuraDefaults.suggestedAssistantNames, id: \.self) { suggestion in
                    Button {
                        name = suggestion
                        commit()
                    } label: {
                        HStack {
                            Text(suggestion)
                                .foregroundStyle(.primary)
                            Spacer()
                            if environment.assistantName == suggestion {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(
                    "Let my style drift toward yours",
                    isOn: Binding(
                        get: { environment.assistantProfile.allowsPersonalityAdaptation },
                        set: { newValue in
                            var mutation = AssistantProfileMutation()
                            mutation.allowsPersonalityAdaptation = newValue
                            Task { await environment.update(mutation) }
                        }
                    )
                )
            } footer: {
                Text("When this is on I'll gradually match how you write. I won't imitate you.")
            }
        }
        .navigationTitle("Assistant")
        .onDisappear(perform: commit)
        .task {
            guard !hasLoaded else { return }
            name = environment.assistantName
            hasLoaded = true
        }
    }

    private func commit() {
        let normalized = AuraDefaults.normalizedAssistantName(name)
        // Reflect the normalisation back into the field, so the user sees what was actually stored
        // rather than believing a trailing space or an over-long name was kept.
        name = normalized
        guard normalized != environment.assistantName else { return }
        var mutation = AssistantProfileMutation()
        mutation.assistantName = normalized
        Task { await environment.update(mutation) }
    }
}

#Preview {
    NavigationStack {
        AssistantSettingsView()
    }
    .environment(AppEnvironment.preview())
}
