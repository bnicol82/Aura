import Foundation
import Observation
import SwiftUI

/// The app's dependency container and shared UI state.
///
/// Constructed once in `AuraApp` and injected through the SwiftUI environment. It is deliberately a
/// *container*, not a view model: it wires dependencies and caches the two singleton profiles that
/// nearly every screen needs. No conversation logic, no prompt assembly, no tool execution — those
/// belong to `AssistantOrchestrator`.
///
/// `@MainActor` because it exists for the UI. The stores it holds are actors of their own, so the
/// work happens off the main thread and only `Sendable` snapshots come back.
@MainActor
@Observable
final class AppEnvironment {

    // MARK: Storage

    let persistence: PersistenceController

    // MARK: Stores

    let assistantProfileStore: AssistantProfileStore
    let userProfileStore: UserProfileStore
    let conversationStore: SwiftDataConversationStore
    /// Exposed so the Memory screens can read and edit what AURA has learned.
    let memoryStore: SwiftDataMemoryStore

    // MARK: Stateless engines

    let personalityEngine = PersonalityEngine()
    let sensitivityClassifier = SensitivityClassifier()

    // MARK: Intelligence

    let networkMonitor: any NetworkStatusProviding
    let personalizationEngine: any PersonalizationEngineProtocol
    let modelRouter: any ModelRouting
    let orchestrator: any AssistantOrchestrating

    /// The live conversation, held here rather than in a view's `@State` so an in-flight turn survives
    /// the user switching tabs mid-answer.
    let conversation: ConversationController

    // MARK: Services

    let credentialStore: any SecureCredentialStoring
    let permissionManager: any PermissionManaging
    /// Exposed so Settings can list the voices actually installed on this device.
    let speechSynthesis: any SpeechSynthesisService
    let toolRegistry: ToolRegistry

    // MARK: Observable state

    /// Cached assistant configuration. Written only by `refreshAssistantProfile()` and `update(_:)`,
    /// so the UI has one source of truth and does not fetch per view.
    private(set) var assistantProfile: AssistantProfileSnapshot = .placeholder

    private(set) var userProfile: UserProfileSnapshot = .placeholder

    /// `false` until the first load finishes, so views can show a settled state rather than
    /// flickering placeholder text into real data.
    private(set) var isLoaded = false

    /// A launch-time problem worth telling the user about — most importantly a store that could not
    /// be opened, which means nothing will be saved this session (§69).
    private(set) var startupError: AuraError?

    /// Whether onboarding has been completed on this device.
    ///
    /// Device-local in `UserDefaults` rather than synced, because it describes whether *this device's*
    /// user has been through setup. Once CloudKit lands in Phase 9 a synced profile will short-circuit
    /// it, which is why `markOnboardingComplete()` is the only writer.
    private(set) var hasCompletedOnboarding: Bool

    private let defaults: UserDefaults
    private static let onboardingCompletedKey = "aura.onboarding.completed"

    /// - Parameters:
    ///   - languageModelProviders: preference order, on-device first. Defaults to Apple's on-device
    ///     model alone; cloud providers are added in V2, and only when the user configures one.
    ///   - networkMonitor: injectable so previews and tests need no radio.
    init(
        persistence: PersistenceController,
        startupError: AuraError? = nil,
        credentialStore: (any SecureCredentialStoring)? = nil,
        permissionManager: (any PermissionManaging)? = nil,
        toolRegistry: ToolRegistry = ToolRegistry(),
        languageModelProviders: [any LanguageModelProvider]? = nil,
        networkMonitor: (any NetworkStatusProviding)? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.persistence = persistence
        self.startupError = startupError

        let assistantProfileStore = AssistantProfileStore(modelContainer: persistence.container)
        let userProfileStore = UserProfileStore(modelContainer: persistence.container)
        let conversationStore = SwiftDataConversationStore(modelContainer: persistence.container)
        self.assistantProfileStore = assistantProfileStore
        self.userProfileStore = userProfileStore
        self.conversationStore = conversationStore

        let monitor = networkMonitor ?? NetworkMonitor()
        self.networkMonitor = monitor

        // Phase 7. The memory store is built first because retrieval, extraction and consolidation all
        // depend on it, and they in turn are what make the assistant learn anything.
        let memoryStore = SwiftDataMemoryStore(modelContainer: persistence.container)
        self.memoryStore = memoryStore

        let memoryRetrieval = DefaultMemoryRetrieval(
            memoryStore: memoryStore,
            userProfileStore: userProfileStore
        )

        let personalizationEngine = DefaultPersonalizationEngine(
            assistantProfileStore: assistantProfileStore,
            userProfileStore: userProfileStore,
            memoryRetrieval: memoryRetrieval
        )
        self.personalizationEngine = personalizationEngine

        let router = DefaultModelRouter(
            providers: languageModelProviders ?? [AppleFoundationModelProvider()],
            networkMonitor: monitor
        )
        self.modelRouter = router

        let orchestrator = AssistantOrchestrator(
            conversationStore: conversationStore,
            personalizationEngine: personalizationEngine,
            router: router,
            assistantProfileStore: assistantProfileStore,
            networkMonitor: monitor,
            memoryExtractor: ModelMemoryExtractor(router: router),
            memoryConsolidator: DefaultMemoryConsolidator(
                memoryStore: memoryStore,
                userProfileStore: userProfileStore
            ),
            userProfileStore: userProfileStore
        )
        self.orchestrator = orchestrator

        // Real by default now that Phase 5 needs microphone and speech authorization. Previews and
        // screenshots still pass a stub explicitly, so nothing headless triggers a system prompt.
        let permissions = permissionManager ?? SystemPermissionManager()
        self.permissionManager = permissions

        let speechRecognition = SystemSpeechRecognitionService(permissions: permissions)
        let speechSynthesis = SystemSpeechSynthesisService()
        self.speechSynthesis = speechSynthesis

        self.conversation = ConversationController(
            orchestrator: orchestrator,
            conversationStore: conversationStore,
            recognition: speechRecognition,
            synthesis: speechSynthesis,
            permissions: permissions,
            assistantProfileStore: assistantProfileStore
        )

        self.credentialStore = credentialStore ?? KeychainCredentialStore()
        self.toolRegistry = toolRegistry
        self.defaults = defaults
        self.hasCompletedOnboarding = defaults.bool(forKey: Self.onboardingCompletedKey)
    }

    // MARK: - Loading

    /// Loads the profiles and provider availability. Called once when the root view appears.
    func load() async {
        await refreshAssistantProfile()
        await refreshUserProfile()
        isLoaded = true
        // Availability is a separate, slower question than "what is my assistant called", so it is not
        // allowed to hold up first paint.
        await refreshProviderStates()
    }

    /// Live model availability, for Settings and the privacy dashboard (§7, §49).
    private(set) var providerStates: [ProviderState] = []

    func refreshProviderStates() async {
        providerStates = await modelRouter.providerStates()
    }

    /// The provider that would answer a plain conversational turn right now.
    var activeProviderState: ProviderState? {
        providerStates.first(where: \.isActiveDefault)
    }

    func refreshAssistantProfile() async {
        do {
            assistantProfile = try await assistantProfileStore.currentProfile()
        } catch {
            report(error)
        }
    }

    func refreshUserProfile() async {
        do {
            userProfile = try await userProfileStore.currentProfile()
        } catch {
            report(error)
        }
    }

    // MARK: - Mutating

    /// Applies an assistant-profile change and refreshes the cache.
    func update(_ mutation: AssistantProfileMutation) async {
        guard !mutation.isEmpty else { return }
        do {
            assistantProfile = try await assistantProfileStore.update(mutation)
        } catch {
            report(error)
        }
    }

    /// Applies a user-profile change and refreshes the cache.
    func update(_ mutation: UserProfileMutation) async {
        guard !mutation.isEmpty else { return }
        do {
            userProfile = try await userProfileStore.update(mutation)
        } catch {
            report(error)
        }
    }

    func markOnboardingComplete() {
        defaults.set(true, forKey: Self.onboardingCompletedKey)
        hasCompletedOnboarding = true
    }

    /// Sends the user back through onboarding. Settings offers this; it does not touch stored data.
    func resetOnboarding() {
        defaults.set(false, forKey: Self.onboardingCompletedKey)
        hasCompletedOnboarding = false
    }

    // MARK: - Derived

    /// The assistant's name, for titles and prompts. Never a hard-coded "AURA" at a call site (§9).
    var assistantName: String { assistantProfile.assistantName }

    /// The greeting for the home screen, or `nil` when the user asked for none.
    func greeting(at date: Date = Date()) -> String? {
        personalityEngine.greeting(
            for: assistantProfile,
            userPreferredName: userProfile.preferredName,
            at: date
        )
    }

    /// `true` when durable data only lives for this session — a store that failed to open. Surfaced
    /// as a banner, because silently discarding what the user says is the worst possible failure.
    var isRunningWithoutPersistence: Bool { persistence.isEphemeral }

    func dismissStartupError() {
        startupError = nil
    }

    private func report(_ error: any Error) {
        let auraError = (error as? AuraError) ?? .saveFailed(reason: error.localizedDescription)
        guard !auraError.isSilent else { return }
        startupError = auraError
        AuraLog.app.error("AppEnvironment operation failed: \(String(describing: auraError), privacy: .public)")
    }
}

// MARK: - Previews

extension AppEnvironment {
    /// An in-memory environment for SwiftUI previews.
    ///
    /// `preconditionFailure` on an unreachable path rather than a silent empty state: an in-memory
    /// SQLite store cannot fail to open in practice, and pretending otherwise would hide a real
    /// schema error behind a blank preview.
    static func preview(
        assistantName: String = "Nova",
        preset: PersonalityPreset = .casual
    ) -> AppEnvironment {
        do {
            let controller = try PersistenceController.inMemory()
            let environment = AppEnvironment(
                persistence: controller,
                credentialStore: InMemoryCredentialStore(),
                permissionManager: StubPermissionManager.allowingEverything(),
                // A mock provider rather than the real one: previews must render identically whether or
                // not the host has Apple Intelligence enabled.
                languageModelProviders: [
                    MockLanguageModelProvider(
                        displayName: "Preview Model",
                        behavior: .respond("You've got three things today — dentist at 2, and the tuition payment is due Friday.")
                    )
                ],
                networkMonitor: StubNetworkMonitor.online
            )
            environment.assistantProfile = AssistantProfileSnapshot(
                assistantName: assistantName,
                personalityPreset: preset,
                style: preset.defaultStyle
            )
            environment.userProfile = UserProfileSnapshot(preferredName: "Alex")
            environment.isLoaded = true
            environment.hasCompletedOnboarding = true
            return environment
        } catch {
            preconditionFailure("Preview container failed — the schema is invalid: \(error)")
        }
    }
}
