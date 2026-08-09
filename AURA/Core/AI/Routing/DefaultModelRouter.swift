import Foundation

/// Chooses which model answers a request (§7).
///
/// Providers are supplied in preference order, on-device first. The router walks that order under three
/// constraints — the user's AI mode, the request's purpose, and live availability — and returns not just
/// a choice but the *reason* for it, because Settings and the privacy dashboard both have to explain
/// what happened.
///
/// ### The rule that outranks the user's own setting
/// `ModelRequestPurpose.isOnDeviceOnly` wins over `.cloudEnhanced`. Memory extraction and
/// classification see the user's raw words before any relevance filtering, so routing them off-device
/// would hand a third party exactly the unfiltered personal material §50 exists to withhold. "Prefer
/// the strongest model" is a quality preference; it is not consent to leak. A router that conflated the
/// two would be a privacy bug wearing a feature's clothes.
///
/// ### Connectivity comes from the caller
/// Routing decisions read `RoutingContext.isOnline` rather than consulting a monitor, which makes
/// `route(purpose:context:)` a function of its arguments and its providers' availability — and so
/// exhaustively testable across every mode × availability × connectivity combination. The injected
/// monitor is used only by `providerStates()`, which has no context to read.
actor DefaultModelRouter: ModelRouting {

    private let providers: [any LanguageModelProvider]
    private let networkMonitor: any NetworkStatusProviding

    /// Availability is cached briefly. Routing runs on every turn, and while
    /// `SystemLanguageModel.availability` is cheap it is not free; a short TTL keeps a burst of turns
    /// from re-querying every provider, while still noticing when Apple Intelligence finishes
    /// downloading its assets.
    private var availabilityCache: [LanguageModelProviderID: (value: ModelAvailability, checkedAt: Date)] = [:]
    private let availabilityCacheLifetime: TimeInterval

    /// - Parameters:
    ///   - providers: preference order, most preferred first. On-device providers should lead.
    ///   - networkMonitor: no default on purpose. A default of "assume online" would make a caller that
    ///     forgot to wire connectivity look like it worked, right up until someone lost signal.
    init(
        providers: [any LanguageModelProvider],
        networkMonitor: any NetworkStatusProviding,
        availabilityCacheLifetime: TimeInterval = 30
    ) {
        self.providers = providers
        self.networkMonitor = networkMonitor
        self.availabilityCacheLifetime = availabilityCacheLifetime
    }

    // MARK: - Routing

    func route(
        purpose: ModelRequestPurpose,
        context: RoutingContext
    ) async throws -> (provider: any LanguageModelProvider, route: ModelRoute) {

        let onDeviceProviders = providers.filter(\.isOnDevice)
        let cloudProviders = providers.filter { !$0.isOnDevice }

        // 1. Purposes pinned to the device. Checked before anything else, including the user's mode.
        if purpose.isOnDeviceOnly {
            if let resolved = await firstAvailable(from: onDeviceProviders) {
                return makeRoute(resolved, reason: .purposeRequiresOnDevice)
            }
            // There is no legitimate fallback here, and inventing one would mean leaking.
            throw AuraError.onDeviceModelUnavailable(
                await bestKnownAvailability(of: onDeviceProviders)
            )
        }

        // 2. The user restricted everything to the device.
        if context.aiMode == .onDeviceOnly {
            if let resolved = await firstAvailable(from: onDeviceProviders) {
                return makeRoute(resolved, reason: .privacyModeRestricted)
            }
            throw AuraError.onDeviceModelUnavailable(
                await bestKnownAvailability(of: onDeviceProviders)
            )
        }

        let cloudIsUsable = context.isOnline && !cloudProviders.isEmpty

        // 3. The user prefers the strongest model available.
        if context.aiMode == .cloudEnhanced, cloudIsUsable,
           let resolved = await firstAvailable(from: cloudProviders) {
            return makeRoute(resolved, reason: .cloudPreferredByUser)
        }

        // 4. A previous attempt overflowed the context window. Retrying into the same window would fail
        //    identically, so escalate to a provider with a larger one if one exists.
        if context.previousFailure == .contextWindowExceeded, cloudIsUsable,
           let resolved = await firstAvailable(from: cloudProviders) {
            return makeRoute(resolved, reason: .escalatedForCapability)
        }

        // 5. Automatic: on-device when it can, cloud when it cannot.
        if let resolved = await firstAvailable(from: onDeviceProviders) {
            return makeRoute(resolved, reason: .onDevicePreferred)
        }

        let onDeviceAvailability = await bestKnownAvailability(of: onDeviceProviders)

        if cloudIsUsable, let resolved = await firstAvailable(from: cloudProviders) {
            return makeRoute(resolved, reason: .onDeviceUnavailable(onDeviceAvailability))
        }

        // 6. Nothing is usable. Report the most actionable reason rather than a generic failure (§69).
        if !cloudProviders.isEmpty, !context.isOnline {
            throw AuraError.noInternetConnection
        }
        if cloudProviders.isEmpty {
            throw AuraError.onDeviceModelUnavailable(onDeviceAvailability)
        }
        throw AuraError.providerNotConfigured(providerName: "A language model")
    }

    // MARK: - Provider states

    func providerStates() async -> [ProviderState] {
        let isOnline = await networkMonitor.isOnline

        // Which provider would answer a plain conversational turn right now, so Settings can mark it.
        let activeID = try? await route(
            purpose: .conversation,
            context: RoutingContext(aiMode: .automatic, isOnline: isOnline)
        ).route.providerID

        var states: [ProviderState] = []
        for provider in providers {
            states.append(
                ProviderState(
                    providerID: provider.id,
                    displayName: provider.displayName,
                    isOnDevice: provider.isOnDevice,
                    availability: await availability(of: provider),
                    isActiveDefault: provider.id == activeID
                )
            )
        }
        return states
    }

    /// Drops cached availability, so a Settings screen can force a fresh check when it appears.
    func invalidateAvailabilityCache() {
        availabilityCache.removeAll()
    }

    // MARK: - Internals

    private func makeRoute(
        _ provider: any LanguageModelProvider,
        reason: ModelRoute.Reason
    ) -> (provider: any LanguageModelProvider, route: ModelRoute) {
        let route = ModelRoute(
            providerID: provider.id,
            providerDisplayName: provider.displayName,
            isOnDevice: provider.isOnDevice,
            reason: reason
        )
        // `.debug` rather than `.info`: this fires on every routing decision, and the memory and
        // summarisation passes route several times per turn. At `.info` it is persisted, and in a test run
        // it floods the log — the last CI run's test output was mostly this one line repeated thousands of
        // times, which buried everything else. Routing is a debugging detail; the route that answered is
        // recorded on the message itself, which is the durable record that matters.
        AuraLog.model.debug(
            "Routed to \(provider.id.rawValue, privacy: .public), on-device: \(provider.isOnDevice, privacy: .public)"
        )
        return (provider, route)
    }

    private func firstAvailable(
        from candidates: [any LanguageModelProvider]
    ) async -> (any LanguageModelProvider)? {
        for provider in candidates {
            if await availability(of: provider).isAvailable {
                return provider
            }
        }
        return nil
    }

    /// The availability worth reporting when a whole group is unusable.
    ///
    /// Prefers a transient reason over a permanent one, because "still getting ready, try again shortly"
    /// is more useful to a person than "not supported" when both are true of different providers.
    private func bestKnownAvailability(
        of candidates: [any LanguageModelProvider]
    ) async -> ModelAvailability {
        guard !candidates.isEmpty else { return .notConfigured }

        var fallback: ModelAvailability = .unknown
        for provider in candidates {
            let value = await availability(of: provider)
            if value.isTransient { return value }
            fallback = value
        }
        return fallback
    }

    private func availability(of provider: any LanguageModelProvider) async -> ModelAvailability {
        let now = Date()
        if let cached = availabilityCache[provider.id],
           now.timeIntervalSince(cached.checkedAt) < availabilityCacheLifetime {
            return cached.value
        }

        let fresh = await provider.availability()
        availabilityCache[provider.id] = (fresh, now)
        return fresh
    }
}
