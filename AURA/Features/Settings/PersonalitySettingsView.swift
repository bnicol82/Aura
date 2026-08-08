import SwiftUI

/// Personality and style (§10, §47).
///
/// The live preview at the top is the point of the screen. Style dials described in words —
/// "formality: neutral" — mean nothing until you see what they produce, so every change re-renders a
/// sample line immediately. The sample is hand-written per configuration rather than generated, which
/// keeps it instant, offline, and identical each time the user returns to a setting.
@MainActor
struct PersonalitySettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var customDescription = ""
    @State private var hasLoaded = false

    var body: some View {
        Form {
            previewSection
            presetSection
            if environment.assistantProfile.personalityPreset == .custom {
                customSection
            }
            dialsSection
            greetingSection
        }
        .navigationTitle("Personality")
        .task {
            guard !hasLoaded else { return }
            customDescription = environment.assistantProfile.customPersonalityPrompt ?? ""
            hasLoaded = true
        }
    }

    // MARK: - Sections

    private var previewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(environment.assistantName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(environment.personalityEngine.stylePreview(for: environment.assistantProfile))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .animation(.easeInOut(duration: 0.2), value: environment.assistantProfile)
            }
            .padding(.vertical, 6)
        } header: {
            Text("How I'll sound")
        }
    }

    private var presetSection: some View {
        Section("Personality") {
            ForEach(PersonalityPreset.allCases) { preset in
                Button {
                    Task { await environment.update(.applying(preset: preset)) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: preset.symbolName)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.displayName)
                                .foregroundStyle(.primary)
                            Text(preset.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        if environment.assistantProfile.personalityPreset == preset {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                // Without this, the default button style tints the whole label, and `.primary` /
                // `.secondary` are *hierarchical* styles — they resolve against the current foreground
                // style, which is the tint. The result is a row of blue text that reads as disabled.
                .buttonStyle(.plain)
            }
        }
    }

    private var customSection: some View {
        Section {
            TextField(
                "For example: funny and sarcastic most of the time, but serious about money and health.",
                text: $customDescription,
                axis: .vertical
            )
            .lineLimit(3...8)
            // No `onSubmit` here: Return inserts a newline in a vertical-axis field, so it would never
            // fire. The button below is the commit path.

            Button("Save description", action: commitCustomDescription)
                .disabled(customDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                    == (environment.assistantProfile.customPersonalityPrompt ?? ""))
        } header: {
            Text("In your words")
        } footer: {
            Text("I'll follow this description, and use the dials below for anything it doesn't cover.")
        }
    }

    private var dialsSection: some View {
        Section {
            Picker("Answer length", selection: responseLengthBinding) {
                ForEach(ResponseLength.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Formality", selection: formalityBinding) {
                ForEach(FormalityLevel.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Humour", selection: humorBinding) {
                ForEach(HumorLevel.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Speaking up", selection: proactivityBinding) {
                ForEach(ProactivityLevel.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Style")
        } footer: {
            Text("Whatever I'm set to, I get serious for health, money, legal and safety topics.")
        }
    }

    private var greetingSection: some View {
        Section("Greeting") {
            Picker("Greeting", selection: greetingBinding) {
                ForEach(GreetingStyle.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    // MARK: - Bindings

    /// Adjusting any individual dial makes the configuration the user's own, so the preset becomes
    /// `.custom` unless they described it in words — which is exactly what "Custom" means in §10.
    private func applyDial(_ configure: (inout AssistantProfileMutation) -> Void) {
        var mutation = AssistantProfileMutation()
        configure(&mutation)
        if environment.assistantProfile.personalityPreset != .custom,
           environment.assistantProfile.customPersonalityPrompt == nil {
            mutation.personalityPreset = .custom
        }
        Task { await environment.update(mutation) }
    }

    private var responseLengthBinding: Binding<ResponseLength> {
        Binding(
            get: { environment.assistantProfile.style.responseLength },
            set: { newValue in applyDial { $0.responseLength = newValue } }
        )
    }

    private var formalityBinding: Binding<FormalityLevel> {
        Binding(
            get: { environment.assistantProfile.style.formality },
            set: { newValue in applyDial { $0.formality = newValue } }
        )
    }

    private var humorBinding: Binding<HumorLevel> {
        Binding(
            get: { environment.assistantProfile.style.humor },
            set: { newValue in applyDial { $0.humor = newValue } }
        )
    }

    private var proactivityBinding: Binding<ProactivityLevel> {
        Binding(
            get: { environment.assistantProfile.style.proactivity },
            set: { newValue in applyDial { $0.proactivity = newValue } }
        )
    }

    private var greetingBinding: Binding<GreetingStyle> {
        Binding(
            get: { environment.assistantProfile.greetingStyle },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.greetingStyle = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    private func commitCustomDescription() {
        var mutation = AssistantProfileMutation()
        mutation.customPersonalityPrompt = .some(customDescription)
        mutation.personalityPreset = .custom
        Task { await environment.update(mutation) }
    }
}

#Preview {
    NavigationStack {
        PersonalitySettingsView()
    }
    .environment(AppEnvironment.preview())
}
