import SwiftUI

/// Settings (§46).
@MainActor
struct SettingsHomeView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                assistantSection
                intelligenceSection
                memorySection
                privacySection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .assistant:
                    AssistantSettingsView()
                case .personality:
                    PersonalitySettingsView()
                case .voice:
                    VoiceSettingsView()
                case .aiModel:
                    AIModelSettingsView()
                case .memory:
                    MemorySettingsView()
                case .whatIKnow:
                    AboutYouView()
                case .privacy:
                    PrivacyDashboardView()
                case .permissions:
                    PermissionsSettingsView()
                }
            }
        }
    }

    private var assistantSection: some View {
        Section("Assistant") {
            NavigationLink(value: SettingsRoute.assistant) {
                SettingsRow(
                    title: "Name",
                    value: environment.assistantName,
                    symbolName: "person.crop.circle"
                )
            }
            NavigationLink(value: SettingsRoute.personality) {
                SettingsRow(
                    title: "Personality",
                    value: environment.assistantProfile.personalityPreset.displayName,
                    symbolName: "theatermasks"
                )
            }
            NavigationLink(value: SettingsRoute.voice) {
                SettingsRow(
                    title: "Voice",
                    value: environment.assistantProfile.voice.speaksResponsesAutomatically ? "Speaks replies" : "Silent",
                    symbolName: "speaker.wave.2"
                )
            }
        }
    }

    private var intelligenceSection: some View {
        Section("Intelligence") {
            NavigationLink(value: SettingsRoute.aiModel) {
                SettingsRow(
                    title: "AI Model",
                    value: environment.assistantProfile.aiMode.displayName,
                    symbolName: "cpu"
                )
            }
        }
    }

    private var memorySection: some View {
        Section("Memory") {
            NavigationLink(value: SettingsRoute.memory) {
                SettingsRow(
                    title: "Memory",
                    value: environment.assistantProfile.memory.automaticMemoryEnabled ? "On" : "Off",
                    symbolName: "brain"
                )
            }
            NavigationLink(value: SettingsRoute.whatIKnow) {
                SettingsRow(
                    title: "What \(environment.assistantName) knows about you",
                    value: "\(environment.userProfile.knownItemCount)",
                    symbolName: "person.text.rectangle"
                )
            }
        }
    }

    private var privacySection: some View {
        Section("Privacy") {
            NavigationLink(value: SettingsRoute.privacy) {
                SettingsRow(title: "Privacy", value: nil, symbolName: "hand.raised")
            }
            NavigationLink(value: SettingsRoute.permissions) {
                SettingsRow(title: "Permissions", value: nil, symbolName: "lock.shield")
            }
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Self.versionString)
            LabeledContent("Storage", value: environment.persistence.sync.statusLabel)
            LabeledContent("Models in schema", value: "\(AuraSchemaV1.models.count)")

            Button("Run setup again") {
                environment.resetOnboarding()
            }
        } header: {
            Text("About")
        } footer: {
            Text("Running setup again lets you rename me or change my personality. It doesn't delete anything.")
        }
    }

    static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

enum SettingsRoute: Hashable {
    case assistant
    case personality
    case voice
    case aiModel
    case memory
    case whatIKnow
    case privacy
    case permissions
}

@MainActor
struct SettingsRow: View {
    let title: String
    let value: String?
    let symbolName: String

    var body: some View {
        Label {
            HStack {
                Text(title)
                    .lineLimit(2)
                Spacer(minLength: 8)
                if let value {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: symbolName)
        }
    }
}

#Preview {
    SettingsHomeView()
        .environment(AppEnvironment.preview())
}
