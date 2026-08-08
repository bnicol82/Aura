import SwiftUI

/// The assistant's home screen (§42).
///
/// Deliberately not a chat log. The centre of the screen is the assistant itself, with the
/// conversation one tap away — which is the difference between "an app that has an AI in it" and
/// "my assistant".
@MainActor
struct AssistantHomeView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var navigationPath = NavigationPath()

    /// Idle in Phase 1. Becomes live state once the voice machine lands in Phase 5.
    private let voiceState: VoiceState = .idle

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 28) {
                    header
                    orb
                    prompt
                    quickActions
                    modelAvailabilityNotice
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(environment.assistantName)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AssistantRoute.self) { route in
                switch route {
                case .conversation:
                    ConversationView()
                case .aboutYou:
                    AboutYouView()
                }
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 6) {
            if let greeting = environment.greeting() {
                Text(greeting)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            Text(statusLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private var orb: some View {
        AssistantOrbView(state: voiceState)
            .frame(width: 190, height: 190)
            .padding(.vertical, 4)
    }

    private var prompt: some View {
        Text("What can I help with?")
            .font(.title3.weight(.medium))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
    }

    private var quickActions: some View {
        // A flexible grid rather than a fixed row, so the labels still fit at large Dynamic Type
        // sizes instead of truncating (§42).
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
            spacing: 12
        ) {
            QuickActionButton(
                title: "Talk",
                symbolName: "mic.fill",
                stage: FeatureFlags.voiceInput
            ) {}

            QuickActionButton(
                title: "Type",
                symbolName: "keyboard",
                stage: .live
            ) {
                navigationPath.append(AssistantRoute.conversation)
            }

            QuickActionButton(
                title: "What I know",
                symbolName: "person.text.rectangle",
                stage: FeatureFlags.manualProfileEditing
            ) {
                navigationPath.append(AssistantRoute.aboutYou)
            }

            QuickActionButton(
                title: "Today",
                symbolName: "sun.horizon",
                stage: FeatureFlags.systemIntegrations
            ) {}
        }
    }

    /// Shown only when the active model cannot currently answer — an ineligible device, Apple
    /// Intelligence switched off, assets still downloading. Says what is wrong and what would fix it,
    /// rather than letting the user discover it by sending a message that fails (§68, §69).
    @ViewBuilder
    private var modelAvailabilityNotice: some View {
        if let state = environment.activeProviderState, !state.availability.isAvailable {
            VStack(alignment: .leading, spacing: 6) {
                Label(state.availability.userFacingDescription, systemImage: "exclamationmark.circle")
                    .font(.footnote)
                if let recovery = state.availability.userFacingRecovery {
                    Text(recovery)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var statusLine: String {
        if environment.userProfile.isEssentiallyEmpty {
            return "We haven't met properly yet. Tell me about yourself whenever you like."
        }
        let count = environment.userProfile.knownItemCount
        return "I'm keeping track of \(count) \(count == 1 ? "thing" : "things") for you."
    }
}

/// Destinations reachable from the assistant tab.
enum AssistantRoute: Hashable {
    case conversation
    case aboutYou
}

/// A home-screen action. Disables itself and explains why when its capability is not live.
@MainActor
private struct QuickActionButton: View {
    let title: String
    let symbolName: String
    let stage: FeatureStage
    let action: () -> Void

    @State private var isShowingNote = false

    var body: some View {
        Button {
            if stage.isLive {
                action()
            } else {
                isShowingNote = true
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: symbolName)
                    .font(.title2)
                    .symbolVariant(.none)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 92)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(stage.isLive ? Color.accentColor : Color.secondary)
            .overlay(alignment: .topTrailing) {
                if let badge = stage.badgeText {
                    Text(badge)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityHint(stage.userFacingNote ?? "")
        .alert(title, isPresented: $isShowingNote) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(stage.userFacingNote ?? "")
        }
    }
}

#Preview {
    AssistantHomeView()
        .environment(AppEnvironment.preview())
}
