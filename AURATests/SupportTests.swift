import Foundation
import Testing

@testable import AURA

@Suite("Assistant name normalisation")
struct AuraDefaultsTests {

    @Test("Names are trimmed, collapsed, and capped")
    func normalisesNames() {
        #expect(AuraDefaults.normalizedAssistantName("  Nova  ") == "Nova")
        #expect(AuraDefaults.normalizedAssistantName("My  Little\nHelper") == "My Little Helper")
        #expect(AuraDefaults.normalizedAssistantName(String(repeating: "x", count: 100)).count
            == AuraDefaults.assistantNameMaxLength)
    }

    @Test("An empty name falls back to the product default")
    func fallsBackWhenEmpty() {
        #expect(AuraDefaults.normalizedAssistantName("") == AuraDefaults.assistantName)
        #expect(AuraDefaults.normalizedAssistantName("   \n ") == AuraDefaults.assistantName)
    }

    @Test("Importance thresholds are ordered as the specification describes")
    func thresholdsAreOrdered() {
        #expect(AuraDefaults.ImportanceThreshold.episodic < AuraDefaults.ImportanceThreshold.durable)
        #expect(AuraDefaults.ImportanceThreshold.durable < AuraDefaults.ImportanceThreshold.explicitRequest)
        #expect(AuraDefaults.Confidence.hedged < AuraDefaults.Confidence.inferred)
        #expect(AuraDefaults.Confidence.inferred < AuraDefaults.Confidence.explicit)
    }
}

@Suite("Keyword tokenisation")
struct TextTokenizationTests {

    @Test("Punctuation is stripped and stop words dropped")
    func tokenises() {
        let tokens = "What did I decide about the garage renovation?".keywordTokens()
        #expect(tokens.contains("decide"))
        #expect(tokens.contains("garage"))
        #expect(tokens.contains("renovation"))
        #expect(!tokens.contains("the"))
        #expect(!tokens.contains("what"))
        #expect(!tokens.contains("?"))
    }

    @Test("Duplicates collapse and case is normalised")
    func deduplicates() {
        #expect("Garage garage GARAGE".keywordTokens() == ["garage"])
    }

    @Test("Negations survive tokenisation, because they change meaning")
    func keepsMeaningfulShortWords() {
        // An aggressive stop list would strip these and invert the sense of a stored memory.
        let tokens = "I do not own a car".keywordTokens()
        #expect(tokens.contains("not"))
        #expect(tokens.contains("car"))
    }

    @Test("Overlap is normalised against the query, so long documents are not penalised")
    func overlapScoring() {
        let query = ["garage", "renovation", "october"]

        #expect(TextTokenization.overlapScore(
            queryTokens: query,
            documentText: "The user is holding off on the garage renovation until October."
        ) == 1)

        let partial = TextTokenization.overlapScore(queryTokens: query, documentText: "garage")
        #expect(abs(partial - 1.0 / 3.0) < 0.0001)

        #expect(TextTokenization.overlapScore(queryTokens: query, documentText: "nothing relevant") == 0)
        #expect(TextTokenization.overlapScore(queryTokens: [], documentText: "anything") == 0)
    }

    @Test("Mid-sentence capitalised words are treated as likely entities")
    func findsProperNouns() {
        let nouns = "Blake is studying at the University of Tennessee.".likelyProperNouns()
        #expect(nouns.contains("University"))
        #expect(nouns.contains("Tennessee"))
        // Sentence-initial words are skipped, since every sentence starts capitalised.
        #expect(!nouns.contains("Blake"))
    }

    @Test("Weekday and time words are not mistaken for entities")
    func ignoresCommonCapitalisedWords() {
        let nouns = "I'll do it Friday or maybe Tomorrow".likelyProperNouns()
        #expect(!nouns.contains("Friday"))
        #expect(!nouns.contains("Tomorrow"))
    }

    @Test("Whitespace normalisation and blank detection")
    func normalisesWhitespace() {
        #expect("  a   b \n c  ".normalizedWhitespace == "a b c")
        #expect("   \n ".isBlank)
        #expect(!"x".isBlank)
    }
}

@Suite("Model availability")
struct ModelAvailabilityTests {

    @Test("Only transient states are worth retrying")
    func transience() {
        #expect(ModelAvailability.modelNotReady.isTransient)
        #expect(ModelAvailability.requiresNetwork.isTransient)
        #expect(ModelAvailability.temporarilyUnavailable(reason: "busy").isTransient)
        #expect(!ModelAvailability.deviceUnsupported.isTransient)
        #expect(!ModelAvailability.appleIntelligenceDisabled.isTransient)
        #expect(!ModelAvailability.available.isTransient)
    }

    @Test("Every unavailable state explains itself")
    func explainsItself() {
        let states: [ModelAvailability] = [
            .deviceUnsupported, .appleIntelligenceDisabled, .modelNotReady,
            .temporarilyUnavailable(reason: "busy"), .notConfigured,
            .requiresNetwork, .blockedByPrivacySetting, .unknown
        ]
        for state in states {
            #expect(!state.userFacingDescription.isEmpty, "\(state) has no description")
            #expect(!state.statusLabel.isEmpty, "\(state) has no status label")
        }
    }

    @Test("States a user can act on offer a recovery step")
    func offersRecoveryWhereActionable() {
        #expect(ModelAvailability.appleIntelligenceDisabled.userFacingRecovery != nil)
        #expect(ModelAvailability.notConfigured.userFacingRecovery != nil)
        #expect(ModelAvailability.blockedByPrivacySetting.userFacingRecovery != nil)
        #expect(ModelAvailability.available.userFacingRecovery == nil)
    }
}

@Suite("Errors")
struct AuraErrorTests {

    @Test("Every error has a user-facing sentence")
    func allErrorsSpeak() {
        let errors: [AuraError] = [
            .onDeviceModelUnavailable(.deviceUnsupported),
            .providerNotConfigured(providerName: "Claude"),
            .cloudDisabledByPrivacySetting,
            .emptyModelResponse,
            .contextWindowExceeded,
            .modelRefusedRequest,
            .modelTimedOut,
            .modelFailed(reason: "upstream error"),
            .noInternetConnection,
            .persistentStoreUnavailable(reason: "locked"),
            .saveFailed(reason: "disk full"),
            .recordNotFound(entity: "Person"),
            .iCloudAccountUnavailable,
            .syncFailed(reason: "conflict"),
            .microphonePermissionDenied,
            .speechRecognitionPermissionDenied,
            .speechRecognitionUnavailable(reason: "no assets"),
            .speechSynthesisUnavailable,
            .permissionDenied(.calendar),
            .toolNotFound(name: "unknown_tool"),
            .toolArgumentsInvalid(toolName: "t", detail: "missing title"),
            .toolConfirmationDeclined(toolName: "t"),
            .toolFailed(toolName: "t", reason: "unavailable"),
            .toolIterationLimitReached(limit: 5),
            .keychainFailure(status: -25300),
            .cancelled
        ]

        for error in errors {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "\(error) has no description")
        }
    }

    @Test("The user's own cancellations stay quiet")
    func silentErrors() {
        #expect(AuraError.cancelled.isSilent)
        #expect(AuraError.toolConfirmationDeclined(toolName: "t").isSilent)
        #expect(!AuraError.noInternetConnection.isSilent)
        #expect(!AuraError.saveFailed(reason: "x").isSilent)
    }

    @Test("An unavailable on-device model reports its own reason and recovery")
    func modelErrorsCarryAvailability() {
        let error = AuraError.onDeviceModelUnavailable(.appleIntelligenceDisabled)
        #expect(error.errorDescription == ModelAvailability.appleIntelligenceDisabled.userFacingDescription)
        #expect(error.recoverySuggestion == ModelAvailability.appleIntelligenceDisabled.userFacingRecovery)
    }
}

@Suite("Feature staging")
struct FeatureStageTests {

    // These tests derive from `FeatureFlags.all` rather than restating which capabilities are pending.
    // The earlier version kept its own hardcoded list and failed the moment Phase 2 flipped two flags
    // to `.live` — asserting the previous phase's reality against current code. A test that has to be
    // edited every time the thing it tests changes is a liability, not a safety net.

    @Test("Every pending capability says what it is waiting on")
    func pendingStagesExplainThemselves() {
        for flag in FeatureFlags.pending {
            #expect(
                flag.stage.userFacingNote?.isEmpty == false,
                "\(flag.name) is pending but has no note for the user"
            )
            #expect(
                flag.stage.badgeText?.isEmpty == false,
                "\(flag.name) is pending but has no phase badge"
            )
        }
    }

    @Test("Every live capability is silent")
    func liveStagesAreSilent() {
        for flag in FeatureFlags.live {
            #expect(
                flag.stage.userFacingNote == nil,
                "\(flag.name) is live but still carries a pending note"
            )
            #expect(
                flag.stage.badgeText == nil,
                "\(flag.name) is live but still carries a phase badge"
            )
        }
    }

    @Test("The registry partitions cleanly into live and pending")
    func registryPartitions() {
        // Enumerating `static let`s to prove none was forgotten would need reflection, so that is not
        // checked here — a second hardcoded mirror of the flag list would just be the same staleness
        // hazard wearing a different hat. What is checked is that `all` is populated and that the two
        // derived views account for every entry exactly once.
        #expect(!FeatureFlags.all.isEmpty)
        #expect(FeatureFlags.live.count + FeatureFlags.pending.count == FeatureFlags.all.count)

        let liveNames = Set(FeatureFlags.live.map(\.name))
        let pendingNames = Set(FeatureFlags.pending.map(\.name))
        #expect(liveNames.isDisjoint(with: pendingNames))
    }

    @Test("Flag names are unique, so a failure message identifies one capability")
    func flagNamesAreUnique() {
        let names = FeatureFlags.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Pending capabilities are ordered by the phase that delivers them")
    func pendingIsOrderedByPhase() {
        let phases = FeatureFlags.pending.compactMap { flag -> Int? in
            guard case .pending(let phase, _, _) = flag.stage else { return nil }
            return phase
        }
        #expect(phases == phases.sorted())
    }

    @Test("Typing always works, and every flag can explain itself")
    func flagsStayHonestWhicheverPhaseThisIs() {
        // This replaced a test that hardcoded "voice is not live yet". That assertion was true when it was
        // written and became false on the commit that shipped voice — so the test failed *because the project
        // made progress*, which is noise rather than signal. Second time this suite has had that shape; the
        // fix both times is to assert the invariant instead of the snapshot.

        // The floor: whatever else is unfinished, AURA must be usable by typing. If this ever goes pending,
        // the app has no working input at all.
        #expect(FeatureFlags.textConversation.isLive)

        // The honesty invariant that actually matters (§78), and it holds in every phase: a pending
        // capability can always explain itself to the user, and a live one never claims to be unfinished.
        for flag in FeatureFlags.all {
            if flag.stage.isLive {
                #expect(flag.stage.userFacingNote == nil, "\(flag.name) is live but still carries a note")
                #expect(flag.stage.badgeText == nil, "\(flag.name) is live but still shows a badge")
            } else {
                #expect(flag.stage.userFacingNote != nil, "\(flag.name) is pending with nothing to tell the user")
                #expect(flag.stage.badgeText != nil, "\(flag.name) is pending with no badge")
            }
        }

        // Something has to be shipped, or the flag table is describing a different app.
        #expect(!FeatureFlags.live.isEmpty)
    }
}

@Suite("Voice state machine")
struct VoiceStateTests {

    @Test("Busy states block a second turn from starting")
    func busyStates() {
        #expect(VoiceState.processing.isBusy)
        #expect(VoiceState.toolExecution(label: "Checking your calendar").isBusy)
        #expect(!VoiceState.idle.isBusy)
        #expect(!VoiceState.listening(transcript: "").isBusy)
        #expect(!VoiceState.speaking.isBusy)
    }

    @Test("Status text shows the live transcript once there is one")
    func statusText() {
        #expect(VoiceState.listening(transcript: "").statusText == "Listening…")
        #expect(VoiceState.listening(transcript: "what's on my").statusText == "what's on my")
        #expect(VoiceState.toolExecution(label: "Checking your calendar").statusText == "Checking your calendar…")
        #expect(VoiceState.error(.noInternetConnection).statusText == AuraError.noInternetConnection.errorDescription)
    }

    @Test("VoiceOver announces the state, not a growing transcript")
    func accessibilityAnnouncement() {
        #expect(VoiceState.listening(transcript: "a very long partial transcript").accessibilityAnnouncement == "Listening")
        #expect(VoiceState.speaking.accessibilityAnnouncement == "Speaking")
    }

    @Test("Tapping interrupts whenever something is under way")
    func interruption() {
        #expect(VoiceState.listening(transcript: "").tapWouldInterrupt)
        #expect(VoiceState.speaking.tapWouldInterrupt)
        #expect(VoiceState.processing.tapWouldInterrupt)
        #expect(!VoiceState.idle.tapWouldInterrupt)
        #expect(!VoiceState.error(.cancelled).tapWouldInterrupt)
    }
}

@Suite("Credential store")
struct CredentialStoreTests {

    @Test("Secrets round-trip and can be deleted")
    func roundTrip() throws {
        // The in-memory store rather than the keychain: keychain access is unavailable in some test
        // environments and shared across runs in others, either of which makes the test lie.
        let store = InMemoryCredentialStore()

        #expect(!store.hasSecret(for: .claudeAPIKey))
        try store.store("secret-value", for: .claudeAPIKey)
        #expect(store.hasSecret(for: .claudeAPIKey))
        #expect(try store.secret(for: .claudeAPIKey) == "secret-value")

        try store.delete(.claudeAPIKey)
        #expect(!store.hasSecret(for: .claudeAPIKey))
    }

    @Test("Deleting all clears every key")
    func deleteAll() throws {
        let store = InMemoryCredentialStore()
        try store.store("a", for: .claudeAPIKey)
        try store.store("b", for: .openAIAPIKey)

        try store.deleteAll()

        for key in CredentialKey.allCases {
            #expect(!store.hasSecret(for: key))
        }
    }
}

@Suite("Permissions")
struct PermissionTests {

    @Test("Authorized and limited both count as usable")
    func usability() {
        #expect(PermissionStatus.authorized.isUsable)
        #expect(PermissionStatus.limited.isUsable)
        #expect(!PermissionStatus.notDetermined.isUsable)
        #expect(!PermissionStatus.denied.isUsable)
        #expect(!PermissionStatus.restricted.isUsable)
    }

    @Test("Every permission explains why it is needed and what breaks without it")
    func everyPermissionExplainsItself() {
        for permission in AuraPermission.allCases {
            #expect(!permission.rationale.isEmpty)
            #expect(!permission.degradationNotice.isEmpty)
            #expect(!permission.displayName.isEmpty)
        }
    }

    @Test("requireUsable prompts once when undetermined and throws when refused")
    func requireUsableFlow() async throws {
        let granting = StubPermissionManager(requestOutcome: .authorized)
        try await granting.requireUsable(.calendar)
        #expect(await granting.status(for: .calendar) == .authorized)

        let refusing = StubPermissionManager(requestOutcome: .denied)
        await #expect(throws: AuraError.permissionDenied(.calendar)) {
            try await refusing.requireUsable(.calendar)
        }
    }

    @Test("An already-denied permission throws without re-prompting")
    func alreadyDeniedDoesNotReprompt() async {
        let manager = StubPermissionManager.denyingEverything()
        await #expect(throws: AuraError.permissionDenied(.microphone)) {
            try await manager.requireUsable(.microphone)
        }
    }
}
