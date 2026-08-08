import Foundation
import Testing

@testable import AURA

@Suite("Model router")
struct ModelRouterTests {

    // MARK: Fixtures

    private func onDevice(_ availability: ModelAvailability = .available) -> MockLanguageModelProvider {
        MockLanguageModelProvider(
            id: .appleOnDevice,
            displayName: "On-device",
            isOnDevice: true,
            availability: availability
        )
    }

    private func cloud(
        id: LanguageModelProviderID = .claude,
        _ availability: ModelAvailability = .available
    ) -> MockLanguageModelProvider {
        MockLanguageModelProvider(
            id: id,
            displayName: "Cloud",
            isOnDevice: false,
            toolExecutionStyle: .orchestratorManaged,
            availability: availability
        )
    }

    private func router(_ providers: [any LanguageModelProvider]) -> DefaultModelRouter {
        // Zero cache lifetime: a test that flips a provider's availability mid-run must see the change.
        DefaultModelRouter(
            providers: providers,
            networkMonitor: StubNetworkMonitor.online,
            availabilityCacheLifetime: 0
        )
    }

    // MARK: On-device pinning

    @Test(
        "Extraction and classification stay on-device in every AI mode",
        arguments: [ModelRequestPurpose.memoryExtraction, .classification]
    )
    func pinnedPurposesNeverLeaveTheDevice(purpose: ModelRequestPurpose) async throws {
        let router = router([onDevice(), cloud()])

        for mode in AIMode.allCases {
            let resolved = try await router.route(
                purpose: purpose,
                context: RoutingContext(aiMode: mode, isOnline: true)
            )
            #expect(resolved.route.isOnDevice, "\(purpose) escaped the device in \(mode) mode")
            #expect(resolved.route.reason == .purposeRequiresOnDevice)
            #expect(!resolved.route.reason.involvedCloudProcessing)
        }
    }

    @Test("A pinned purpose fails rather than falling back to the cloud")
    func pinnedPurposeFailsClosed() async {
        // Cloud is available and the user asked for cloud-enhanced. Extraction still must not go there.
        let router = router([onDevice(.deviceUnsupported), cloud()])

        await #expect(throws: AuraError.onDeviceModelUnavailable(.deviceUnsupported)) {
            _ = try await router.route(
                purpose: .memoryExtraction,
                context: RoutingContext(aiMode: .cloudEnhanced, isOnline: true)
            )
        }
    }

    // MARK: Modes

    @Test("On-device-only mode never reaches a cloud provider")
    func onDeviceOnlyMode() async throws {
        let router = router([onDevice(), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .onDeviceOnly, isOnline: true)
        )
        #expect(resolved.route.isOnDevice)
        #expect(resolved.route.reason == .privacyModeRestricted)
    }

    @Test("On-device-only mode fails with the real reason when the model is unavailable")
    func onDeviceOnlyModeFailure() async {
        let router = router([onDevice(.appleIntelligenceDisabled), cloud()])
        await #expect(throws: AuraError.onDeviceModelUnavailable(.appleIntelligenceDisabled)) {
            _ = try await router.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .onDeviceOnly, isOnline: true)
            )
        }
    }

    @Test("Automatic mode prefers the on-device model when it is available")
    func automaticPrefersOnDevice() async throws {
        let router = router([onDevice(), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .automatic, isOnline: true)
        )
        #expect(resolved.route.isOnDevice)
        #expect(resolved.route.reason == .onDevicePreferred)
        #expect(!resolved.route.reason.involvedCloudProcessing)
    }

    @Test("Automatic mode falls back to the cloud with the on-device reason attached")
    func automaticFallsBack() async throws {
        let router = router([onDevice(.deviceUnsupported), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .automatic, isOnline: true)
        )
        #expect(!resolved.route.isOnDevice)
        #expect(resolved.route.reason == .onDeviceUnavailable(.deviceUnsupported))
        #expect(resolved.route.reason.involvedCloudProcessing)
        // The explanation has to name the cause, so Settings is not left saying "something happened".
        #expect(resolved.route.reason.userFacingExplanation.contains("Not supported"))
    }

    @Test("Cloud-enhanced mode prefers a cloud provider")
    func cloudEnhancedPrefersCloud() async throws {
        let router = router([onDevice(), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .cloudEnhanced, isOnline: true)
        )
        #expect(!resolved.route.isOnDevice)
        #expect(resolved.route.reason == .cloudPreferredByUser)
    }

    @Test("Cloud-enhanced mode still uses the on-device model when offline")
    func cloudEnhancedOfflineUsesOnDevice() async throws {
        let router = router([onDevice(), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .cloudEnhanced, isOnline: false)
        )
        #expect(resolved.route.isOnDevice)
        #expect(resolved.route.reason == .onDevicePreferred)
    }

    // MARK: Escalation

    @Test("A context-window failure escalates to a cloud provider")
    func escalatesAfterContextOverflow() async throws {
        let router = router([onDevice(), cloud()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(
                aiMode: .automatic,
                isOnline: true,
                previousFailure: .contextWindowExceeded
            )
        )
        #expect(!resolved.route.isOnDevice)
        #expect(resolved.route.reason == .escalatedForCapability)
    }

    @Test("With no cloud provider, a context-window failure stays on-device rather than failing")
    func escalationWithoutCloudStaysPut() async throws {
        let router = router([onDevice()])
        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(
                aiMode: .automatic,
                isOnline: true,
                previousFailure: .contextWindowExceeded
            )
        )
        #expect(resolved.route.isOnDevice)
    }

    // MARK: Nothing usable

    @Test("With only a cloud provider and no network, the error is about the network")
    func offlineWithOnlyCloud() async {
        let router = router([cloud()])
        await #expect(throws: AuraError.noInternetConnection) {
            _ = try await router.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .automatic, isOnline: false)
            )
        }
    }

    @Test("With only an unavailable on-device provider, the error is about the model")
    func onlyUnavailableOnDevice() async {
        let router = router([onDevice(.appleIntelligenceDisabled)])
        await #expect(throws: AuraError.onDeviceModelUnavailable(.appleIntelligenceDisabled)) {
            _ = try await router.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .automatic, isOnline: true)
            )
        }
    }

    @Test("With no providers at all, the error says nothing is configured")
    func noProviders() async {
        let router = router([])
        await #expect(throws: AuraError.onDeviceModelUnavailable(.notConfigured)) {
            _ = try await router.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .automatic, isOnline: true)
            )
        }
    }

    @Test("A transient reason is preferred over a permanent one when reporting a group failure")
    func prefersTransientReason() async {
        // Two on-device providers: one will never work, one is still downloading. "Still getting ready"
        // is the more useful thing to tell a person.
        let router = router([onDevice(.deviceUnsupported), onDevice(.modelNotReady)])
        await #expect(throws: AuraError.onDeviceModelUnavailable(.modelNotReady)) {
            _ = try await router.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .onDeviceOnly, isOnline: true)
            )
        }
    }

    // MARK: Preference order

    @Test("Among cloud providers, the first available in preference order wins")
    func respectsPreferenceOrder() async throws {
        let first = cloud(id: .claude, .notConfigured)
        let second = cloud(id: .openAI, .available)
        let router = router([onDevice(.deviceUnsupported), first, second])

        let resolved = try await router.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .cloudEnhanced, isOnline: true)
        )
        #expect(resolved.route.providerID == .openAI)
    }

    // MARK: Provider states

    @Test("Provider states report availability and mark the one in use")
    func providerStates() async throws {
        let router = router([onDevice(), cloud()])
        let states = await router.providerStates()

        #expect(states.count == 2)
        #expect(states.filter(\.isActiveDefault).count == 1)
        #expect(states.first(where: \.isOnDevice)?.isActiveDefault == true)
        #expect(states.allSatisfy { $0.availability == .available })
    }

    @Test("Provider states mark nothing active when nothing can answer")
    func providerStatesWithNothingAvailable() async {
        let router = router([onDevice(.deviceUnsupported)])
        let states = await router.providerStates()

        #expect(states.count == 1)
        #expect(states.allSatisfy { !$0.isActiveDefault })
        #expect(states.first?.availability == .deviceUnsupported)
    }

    // MARK: Caching

    @Test("Availability is cached for its lifetime, then re-read")
    func cachesAvailability() async throws {
        let provider = onDevice(.available)
        let cachingRouter = DefaultModelRouter(
            providers: [provider],
            networkMonitor: StubNetworkMonitor.online,
            availabilityCacheLifetime: 600
        )

        _ = try await cachingRouter.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .automatic, isOnline: true)
        )

        // The provider becomes unavailable, but the cache should still be warm.
        provider.setAvailability(.appleIntelligenceDisabled)
        let stillCached = try await cachingRouter.route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .automatic, isOnline: true)
        )
        #expect(stillCached.route.isOnDevice)

        // Invalidating is what a Settings screen does on appear.
        await cachingRouter.invalidateAvailabilityCache()
        await #expect(throws: AuraError.onDeviceModelUnavailable(.appleIntelligenceDisabled)) {
            _ = try await cachingRouter.route(
                purpose: .conversation,
                context: RoutingContext(aiMode: .automatic, isOnline: true)
            )
        }
    }
}
