import SwiftUI

/// Voice preferences (§39, §47).
///
/// The voice picker lists what is actually installed rather than everything Apple ships, because
/// selecting an uninstalled voice silently falls back to the default — which reads as a bug. Phase 5
/// populates the list from `AVSpeechSynthesisVoice`; until then the preference rows still work and the
/// picker says why it is empty.
@MainActor
struct VoiceSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Filled in Phase 5 by `SpeechSynthesisService.availableVoices()`.
    @State private var voices: [AssistantVoice] = []

    var body: some View {
        Form {
            Section {
                Toggle("Speak replies out loud", isOn: speaksAutomaticallyBinding)
            } footer: {
                Text("When this is off I'll still answer — you'll just read it instead.")
            }

            Section {
                if voices.isEmpty {
                    PendingFeatureNotice(stage: FeatureFlags.voiceOutput, symbolName: "speaker.wave.2")
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                } else {
                    Picker("Voice", selection: voiceBinding) {
                        Text("System default").tag(String?.none)
                        ForEach(voices) { voice in
                            Text(voice.displayName).tag(Optional(voice.id))
                        }
                    }
                }
            } header: {
                Text("Voice")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Speaking rate")
                        Spacer()
                        Text(rateLabel)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: speechRateBinding, in: 0.25...0.85, step: 0.05) {
                        Text("Speaking rate")
                    } minimumValueLabel: {
                        Image(systemName: "tortoise")
                    } maximumValueLabel: {
                        Image(systemName: "hare")
                    }
                }
            }
        }
        .navigationTitle("Voice")
    }

    private var rateLabel: String {
        let rate = environment.assistantProfile.voice.speechRate
        switch rate {
        case ..<0.4: return "Slower"
        case 0.4..<0.6: return "Normal"
        case 0.6..<0.75: return "Faster"
        default: return "Fastest"
        }
    }

    private var speaksAutomaticallyBinding: Binding<Bool> {
        Binding(
            get: { environment.assistantProfile.voice.speaksResponsesAutomatically },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.speaksResponsesAutomatically = newValue
                Task { await environment.update(mutation) }
            }
        )
    }

    private var voiceBinding: Binding<String?> {
        Binding(
            get: { environment.assistantProfile.voice.voiceIdentifier },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.voiceIdentifier = .some(newValue)
                Task { await environment.update(mutation) }
            }
        )
    }

    private var speechRateBinding: Binding<Double> {
        Binding(
            get: { environment.assistantProfile.voice.speechRate },
            set: { newValue in
                var mutation = AssistantProfileMutation()
                mutation.speechRate = newValue
                Task { await environment.update(mutation) }
            }
        )
    }
}

#Preview {
    NavigationStack {
        VoiceSettingsView()
    }
    .environment(AppEnvironment.preview())
}
