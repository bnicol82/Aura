import SwiftData
import SwiftUI

/// `@MainActor` is stated rather than relied upon: `AppEnvironment.init` is main-actor isolated, and
/// this initializer calls it. SwiftUI's `App` protocol carries the isolation itself in current SDKs,
/// but writing it down means this file does not depend on that continuing to be true.
@main
@MainActor
struct AuraApp: App {

    @State private var appEnvironment: AppEnvironment

    init() {
        // The store is opened before any view exists, so a failure can be reported rather than
        // crashing. `makeForApp()` falls back to an in-memory store and hands back the reason, which
        // the root view shows as a banner (§69).
        let (controller, failure) = PersistenceController.makeForApp()
        _appEnvironment = State(
            initialValue: AppEnvironment(persistence: controller, startupError: failure)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appEnvironment)
                // Views browse with `@Query` against this container; the store actors write to the
                // same one. One container, one store file.
                .modelContainer(appEnvironment.persistence.container)
        }
    }
}
