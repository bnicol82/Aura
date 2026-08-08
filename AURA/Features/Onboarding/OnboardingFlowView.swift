import SwiftUI

/// The setup flow (§53).
///
/// Ten screens in the specification, seven here. Three were folded in rather than dropped:
///
/// * **Style** (spec screen 4) is merged into the personality screen, where the live preview makes the
///   dials mean something instead of being four abstract pickers on their own page.
/// * **"What should I remember?"** (spec screen 7) becomes an optional prompt on the memory screen.
///   Its own page turns setup into the questionnaire §26 explicitly warns against.
/// * **Voice** (spec screen 9) is skipped entirely until Phase 5 delivers speech. Asking someone to
///   pick a voice that cannot speak yet would be exactly the pretence §75 forbids.
///
/// No system permissions are requested anywhere in here (§53).
@MainActor
struct OnboardingFlowView: View {
    @Environment(AppEnvironment.self) private var environment

    #if DEBUG
    /// Screenshot mode opens the flow at a specific step. Debug-only: a release build has no way to
    /// enter onboarding partway through.
    var initialStep: Step?
    #endif

    @State private var step: Step = .welcome
    @State private var assistantName = AuraDefaults.assistantName
    @State private var userName = ""
    @State private var customPersonality = ""
    @State private var memoryEnabled = true
    @State private var thingsToRemember = ""

    enum Step: Int, CaseIterable, Comparable {
        case welcome
        case name
        case personality
        case yourName
        case memory
        case aiMode
        case ready

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// The welcome and ready screens are not part of the progress count.
        var isProgressStep: Bool { self != .welcome && self != .ready }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step.isProgressStep {
                    ProgressView(value: progressFraction)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                ScrollView {
                    content
                        .padding(.horizontal, 24)
                        .padding(.top, 24)
                        .padding(.bottom, 32)
                        .frame(maxWidth: .infinity)
                }

                footer
            }
            .background(Color(.systemBackground))
            .animation(.easeInOut(duration: 0.25), value: step)
            #if DEBUG
            .task {
                if let initialStep { step = initialStep }
            }
            #endif
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep()
        case .name:
            OnboardingNameStep(assistantName: $assistantName)
        case .personality:
            OnboardingPersonalityStep(customPersonality: $customPersonality)
        case .yourName:
            OnboardingUserNameStep(assistantName: environment.assistantName, userName: $userName)
        case .memory:
            OnboardingMemoryStep(
                assistantName: environment.assistantName,
                memoryEnabled: $memoryEnabled,
                thingsToRemember: $thingsToRemember
            )
        case .aiMode:
            OnboardingAIModeStep()
        case .ready:
            OnboardingReadyStep(assistantName: environment.assistantName)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: advance) {
                Text(primaryButtonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canAdvance)

            if step != .welcome, step != .ready {
                Button("Back", action: goBack)
                    .font(.footnote)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 12)
        .background(.bar)
    }

    // MARK: - Navigation

    private var progressFraction: Double {
        let progressSteps = Step.allCases.filter(\.isProgressStep)
        guard let index = progressSteps.firstIndex(of: step) else { return 0 }
        return Double(index + 1) / Double(progressSteps.count)
    }

    private var primaryButtonTitle: String {
        switch step {
        case .welcome: return "Get started"
        // Not "Start talking": the same screen says voice is not wired up yet, and typing is what
        // actually works today. A button promising the one unbuilt feature is the pretence §75 forbids.
        case .ready: return "Start chatting"
        case .memory: return memoryEnabled ? "Enable memory" : "Not now"
        default: return "Continue"
        }
    }

    private var canAdvance: Bool {
        switch step {
        case .name: return !assistantName.isBlank
        default: return true
        }
    }

    private func advance() {
        // Each step commits its own answer as it is left, so quitting setup halfway keeps what was
        // already chosen instead of discarding it.
        switch step {
        case .name:
            commitAssistantName()
        case .personality:
            commitCustomPersonality()
        case .yourName:
            commitUserName()
        case .memory:
            commitMemoryPreferences()
        case .welcome, .aiMode, .ready:
            break
        }

        guard let next = Step(rawValue: step.rawValue + 1) else {
            environment.markOnboardingComplete()
            return
        }
        step = next
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: - Commits

    private func commitAssistantName() {
        let normalized = AuraDefaults.normalizedAssistantName(assistantName)
        assistantName = normalized
        var mutation = AssistantProfileMutation()
        mutation.assistantName = normalized
        Task { await environment.update(mutation) }
    }

    private func commitCustomPersonality() {
        guard environment.assistantProfile.personalityPreset == .custom else { return }
        var mutation = AssistantProfileMutation()
        mutation.customPersonalityPrompt = .some(customPersonality)
        Task { await environment.update(mutation) }
    }

    private func commitUserName() {
        var mutation = UserProfileMutation()
        mutation.preferredName = .some(userName)
        Task { await environment.update(mutation) }
    }

    private func commitMemoryPreferences() {
        var assistantMutation = AssistantProfileMutation()
        assistantMutation.automaticMemoryEnabled = memoryEnabled
        assistantMutation.usesMemoryInResponses = memoryEnabled

        // Free text from the optional prompt becomes standing instructions, which is where §29 says
        // the user's own words belong — outranking anything inferred later.
        let instructions = thingsToRemember
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var profileMutation = UserProfileMutation()
        if !instructions.isEmpty {
            profileMutation.assistantInstructions = instructions
        }

        Task {
            await environment.update(assistantMutation)
            if !profileMutation.isEmpty {
                await environment.update(profileMutation)
            }
        }
    }
}

#Preview {
    OnboardingFlowView()
        .environment(AppEnvironment.preview())
}
