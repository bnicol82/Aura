import SwiftUI

/// Shared layout for a setup screen, so the seven steps share one rhythm.
@MainActor
struct OnboardingStepScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    var symbolName: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 1. Welcome

@MainActor
struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 28) {
            AssistantOrbView(state: .idle)
                .frame(width: 170, height: 170)
                .padding(.top, 20)

            VStack(spacing: 12) {
                Text("Meet AURA")
                    .font(.largeTitle.weight(.bold))
                Text("A private personal assistant that remembers what matters to you.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                WelcomePoint(
                    symbolName: "iphone",
                    text: "Runs on your iPhone. Your information stays with you."
                )
                WelcomePoint(
                    symbolName: "brain",
                    text: "Remembers the people, projects and preferences you tell it about."
                )
                WelcomePoint(
                    symbolName: "slider.horizontal.3",
                    text: "You choose its name, its personality, and what it's allowed to know."
                )
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

@MainActor
private struct WelcomePoint: View {
    let symbolName: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 26)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 2. Name the assistant

@MainActor
struct OnboardingNameStep: View {
    @Binding var assistantName: String

    var body: some View {
        OnboardingStepScaffold(
            title: "What should I be called?",
            subtitle: "Pick a name, or use your own. You can change it whenever you like.",
            symbolName: "person.crop.circle"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                TextField("Assistant name", text: $assistantName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(.title3)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                    ForEach(AuraDefaults.suggestedAssistantNames, id: \.self) { suggestion in
                        Button {
                            assistantName = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    assistantName == suggestion ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - 3. Personality (spec screens 3 and 4, combined)

@MainActor
struct OnboardingPersonalityStep: View {
    @Environment(AppEnvironment.self) private var environment
    @Binding var customPersonality: String

    var body: some View {
        OnboardingStepScaffold(
            title: "How should I talk?",
            subtitle: "Pick a starting point, then adjust anything. You'll see the difference straight away.",
            symbolName: "theatermasks"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                // The preview sits above the choices, so a tap changes something the user can see
                // without scrolling.
                VStack(alignment: .leading, spacing: 6) {
                    Text(environment.assistantName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(environment.personalityEngine.stylePreview(for: environment.assistantProfile))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .animation(.easeInOut(duration: 0.2), value: environment.assistantProfile)

                VStack(spacing: 8) {
                    ForEach(PersonalityPreset.allCases) { preset in
                        PresetButton(
                            preset: preset,
                            isSelected: environment.assistantProfile.personalityPreset == preset
                        ) {
                            Task { await environment.update(.applying(preset: preset)) }
                        }
                    }
                }

                if environment.assistantProfile.personalityPreset == .custom {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Describe what you want")
                            .font(.subheadline.weight(.medium))
                        TextField(
                            "Funny and sarcastic most of the time, but serious about money and health.",
                            text: $customPersonality,
                            axis: .vertical
                        )
                        .lineLimit(3...6)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                DisclosureGroup("Fine-tune") {
                    VStack(spacing: 12) {
                        StyleDialRow(title: "Answer length") {
                            Picker("Answer length", selection: responseLengthBinding) {
                                ForEach(ResponseLength.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        StyleDialRow(title: "Humour") {
                            Picker("Humour", selection: humorBinding) {
                                ForEach(HumorLevel.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        StyleDialRow(title: "Speaking up") {
                            Picker("Speaking up", selection: proactivityBinding) {
                                ForEach(ProactivityLevel.allCases) { Text($0.displayName).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }

    private func applyDial(_ configure: (inout AssistantProfileMutation) -> Void) {
        var mutation = AssistantProfileMutation()
        configure(&mutation)
        Task { await environment.update(mutation) }
    }

    private var responseLengthBinding: Binding<ResponseLength> {
        Binding(
            get: { environment.assistantProfile.style.responseLength },
            set: { value in applyDial { $0.responseLength = value } }
        )
    }

    private var humorBinding: Binding<HumorLevel> {
        Binding(
            get: { environment.assistantProfile.style.humor },
            set: { value in applyDial { $0.humor = value } }
        )
    }

    private var proactivityBinding: Binding<ProactivityLevel> {
        Binding(
            get: { environment.assistantProfile.style.proactivity },
            set: { value in applyDial { $0.proactivity = value } }
        )
    }
}

@MainActor
private struct StyleDialRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
private struct PresetButton: View {
    let preset: PersonalityPreset
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preset.symbolName)
                    .frame(width: 24)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 4. The user's name

@MainActor
struct OnboardingUserNameStep: View {
    let assistantName: String
    @Binding var userName: String

    var body: some View {
        OnboardingStepScaffold(
            title: "What should I call you?",
            subtitle: "Optional. If you skip it, I just won't use a name — I won't guess one.",
            symbolName: "hand.wave"
        ) {
            TextField("Your name", text: $userName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(.title3)
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - 5. Memory (spec screens 6 and 7, combined)

@MainActor
struct OnboardingMemoryStep: View {
    let assistantName: String
    @Binding var memoryEnabled: Bool
    @Binding var thingsToRemember: String

    var body: some View {
        OnboardingStepScaffold(
            title: "Should I remember things?",
            subtitle: "With memory on, \(assistantName) keeps the useful parts of your conversations — people, preferences, decisions, commitments — and skips the rest.",
            symbolName: "brain"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Toggle("Remember useful things between conversations", isOn: $memoryEnabled)
                    .padding(14)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        "Everything I remember is visible and editable, and you can delete any of it.",
                        systemImage: "eye"
                    )
                    Label(
                        "Deciding what's worth keeping always happens on this iPhone.",
                        systemImage: "iphone"
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if memoryEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Anything I should always keep in mind?")
                            .font(.subheadline.weight(.medium))
                        Text("Optional. Separate several with commas.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextField(
                            "Keep answers short, always show me the numbers…",
                            text: $thingsToRemember,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        .padding(12)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }
}

// MARK: - 6. AI mode

@MainActor
struct OnboardingAIModeStep: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        OnboardingStepScaffold(
            title: "Where should I think?",
            subtitle: "Automatic is the recommended balance. You can change this any time in Settings.",
            symbolName: "cpu"
        ) {
            VStack(spacing: 8) {
                ForEach(AIMode.allCases) { mode in
                    Button {
                        var mutation = AssistantProfileMutation()
                        mutation.aiMode = mode
                        Task { await environment.update(mutation) }
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: symbolName(for: mode))
                                .frame(width: 24)
                                .foregroundStyle(environment.assistantProfile.aiMode == mode ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(mode.displayName)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if mode == .automatic {
                                        Text("Recommended")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.tint.opacity(0.15), in: Capsule())
                                    }
                                }
                                Text(mode.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if environment.assistantProfile.aiMode == mode {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            environment.assistantProfile.aiMode == mode
                                ? Color.accentColor.opacity(0.12)
                                : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
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

// MARK: - 7. Ready

@MainActor
struct OnboardingReadyStep: View {
    let assistantName: String

    var body: some View {
        VStack(spacing: 28) {
            AssistantOrbView(state: .idle)
                .frame(width: 170, height: 170)
                .padding(.top, 24)

            VStack(spacing: 12) {
                Text("I'm \(assistantName).")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Ask me something, or tell me about yourself whenever you like.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Typing works as of Phase 2. Talking does not, and setup says so rather than implying the
            // microphone is live (§75).
            PendingFeatureNotice(
                stage: FeatureFlags.voiceInput,
                symbolName: "mic.slash"
            )
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview("Welcome") {
    OnboardingWelcomeStep()
        .padding()
        .environment(AppEnvironment.preview())
}

#Preview("Personality") {
    ScrollView {
        OnboardingPersonalityStep(customPersonality: .constant(""))
            .padding()
    }
    .environment(AppEnvironment.preview())
}
