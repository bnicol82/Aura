#if DEBUG

import SwiftData
import SwiftUI

/// Renders any single screen directly, with realistic data, for automated screenshots.
///
/// ### Why this exists
/// The person building AURA has an iPhone and no Mac, so they cannot run the app. Screenshots from CI
/// are how they see what is being made. Driving the UI with XCUITest taps would work, but it is slow,
/// brittle, and needs a whole extra target; jumping straight to a screen is none of those things.
///
/// ### Why it cannot ship
/// The entire file is inside `#if DEBUG`, and the one branch in `RootView` that reaches it is too. A
/// release build contains none of this — no launch flag, no seeded store, no bypass of onboarding.
///
/// ### How CI drives it
/// ```
/// xcrun simctl launch booted com.aura.assistant -AURAScreenshotScreen home
/// ```
/// `-key value` launch arguments land in `UserDefaults`' argument domain automatically, so no manual
/// parsing is needed.
enum ScreenshotMode {

    static let launchArgumentKey = "AURAScreenshotScreen"

    /// Every screen worth looking at, in the order a person would meet them.
    enum Screen: String, CaseIterable {
        case onboardingWelcome
        case onboardingName
        case onboardingPersonality
        case onboardingMemory
        case onboardingReady
        case home
        case conversation
        case conversationHistory
        case memoryHome
        case aboutYou
        case people
        case personDetail
        case facts
        case settings
        case personalitySettings
        case aiModel
        case privacy
        case activity
    }

    /// The screen CI asked for, or `nil` in normal use.
    static var requestedScreen: Screen? {
        guard let raw = UserDefaults.standard.string(forKey: launchArgumentKey) else { return nil }
        return Screen(rawValue: raw)
    }

    static var isActive: Bool { requestedScreen != nil }
}

// MARK: - Seeded data

extension ScreenshotMode {

    /// Identifiers of the seeded records, so a detail screen can be pointed at one.
    struct SeededIDs {
        var personID: UUID?
        var conversationID: UUID?
    }

    /// An in-memory environment populated with the specification's own example data.
    ///
    /// Deliberately uses §2's scenario — Nova, Blake studying at Tennessee, the garage renovation held
    /// until October — so the screenshots show the product doing the thing it was designed for, rather
    /// than lorem ipsum.
    @MainActor
    static func makeSeededEnvironment() async -> (environment: AppEnvironment, ids: SeededIDs) {
        let controller: PersistenceController
        do {
            controller = try PersistenceController.inMemory()
        } catch {
            preconditionFailure("Screenshot mode could not create an in-memory store: \(error)")
        }

        let environment = AppEnvironment(
            persistence: controller,
            credentialStore: InMemoryCredentialStore(),
            permissionManager: StubPermissionManager.allowingEverything(),
            // Seeded stubs rather than the real frameworks: a screenshot run is headless, and a system
            // permission prompt would block it forever. The events are §2's scenario.
            calendarService: ScreenshotMode.seededCalendar(),
            contactLookupService: ScreenshotMode.seededContacts(),
            // A mock provider, so a screenshot never depends on whether the host has Apple
            // Intelligence. It also means the conversation screen has a real reply to show.
            languageModelProviders: [
                MockLanguageModelProvider(
                    displayName: "Apple Intelligence",
                    isOnDevice: true,
                    behavior: .respond("You decided to hold off on the garage renovation until October.")
                )
            ],
            networkMonitor: StubNetworkMonitor.online,
            // A throwaway defaults suite, so screenshot runs never touch the real onboarding flag.
            defaults: UserDefaults(suiteName: "com.aura.assistant.screenshots") ?? .standard
        )

        var ids = SeededIDs()

        do {
            var assistant = AssistantProfileMutation.applying(preset: .casual)
            assistant.assistantName = "Nova"
            _ = try await environment.assistantProfileStore.update(assistant)

            var profile = UserProfileMutation()
            profile.preferredName = .some("Alex")
            profile.workContext = .some("Runs a small construction business")
            profile.interests = ["NASCAR", "Woodworking", "Fantasy golf"]
            profile.longTermGoals = ["Finish the garage", "Get Blake through school debt-free"]
            profile.routines = ["Gym before work on weekdays", "Sunday dinner with the family"]
            profile.assistantInstructions = ["Keep answers short", "Always show me the numbers"]
            _ = try await environment.userProfileStore.update(profile)

            let blake = try await environment.userProfileStore.createPerson(
                name: "Blake", relationship: "son", sourceMemoryID: nil
            )
            ids.personID = blake.id

            var blakeDetails = PersonProfileMutation()
            blakeDetails.education = .some("Mechanical Engineering at the University of Tennessee")
            blakeDetails.interests = ["Mountain biking", "Rocketry"]
            blakeDetails.importantFacts = ["Switched from aerospace to mechanical engineering"]
            _ = try await environment.userProfileStore.updatePerson(id: blake.id, with: blakeDetails)

            let jennifer = try await environment.userProfileStore.createPerson(
                name: "Jennifer", relationship: "wife", sourceMemoryID: nil
            )
            var jenniferDetails = PersonProfileMutation()
            jenniferDetails.preferences = ["Favourite colour is sage green", "Prefers aisle seats"]
            _ = try await environment.userProfileStore.updatePerson(id: jennifer.id, with: jenniferDetails)

            let calendar = Calendar.current
            if let birthday = calendar.date(from: DateComponents(year: 1985, month: 5, day: 6)) {
                _ = try await environment.userProfileStore.addImportantDate(
                    toPersonID: jennifer.id,
                    title: "Jennifer's birthday",
                    date: birthday,
                    isRecurringAnnually: true,
                    sourceMemoryID: nil
                )
            }

            for fact in seededFacts {
                _ = try await environment.userProfileStore.upsertFact(
                    key: fact.key,
                    value: fact.value,
                    category: fact.category,
                    confidence: fact.confidence,
                    sourceMemoryID: nil
                )
            }

            let conversation = try await environment.conversationStore.createConversation(
                title: nil, at: Date().addingTimeInterval(-600)
            )
            ids.conversationID = conversation.id
            for message in seededMessages {
                _ = try await environment.conversationStore.appendMessage(
                    message, toConversationID: conversation.id
                )
            }

            // Phase 13. Seeded so the Activity screen shows what an audit trail actually looks like —
            // including a refusal and a failure, because a screenshot of nothing but ticks would
            // misrepresent the one screen whose job is to show what went wrong too (§36).
            await environment.activityLog.record(
                kind: .memorySaved, title: "Remembered", detail: "Holding the garage until October"
            )
            await environment.activityLog.record(
                kind: .toolExecuted, title: "Checked your calendar", detail: "3 events"
            )
            await environment.activityLog.record(
                kind: .toolExecuted,
                title: "Set a reminder",
                detail: "Pay Blake's tuition",
                succeeded: true,
                references: .none
            )
            await environment.activityLog.record(
                kind: .memoryDeleted,
                title: "Forgetting that",
                detail: "You said no",
                succeeded: false,
                references: .none
            )

            await environment.load()
            // Picks up the seeded conversation, so the transcript is populated on screen.
            await environment.conversation.prepare()
        } catch {
            // A screenshot of an empty screen is still a useful screenshot; a crash is not.
            AuraLog.app.error("Screenshot seeding failed partway: \(error.localizedDescription, privacy: .public)")
        }

        return (environment, ids)
    }

    private struct SeededFact {
        let key: String
        let value: String
        let category: MemoryCategory
        var confidence: Double = AuraDefaults.Confidence.explicit
    }

    private static var seededFacts: [SeededFact] {
        [
            SeededFact(key: "Favourite NASCAR driver", value: "Christopher Bell", category: .sports),
            SeededFact(key: "Preferred seat", value: "Aisle", category: .travel),
            SeededFact(key: "Coffee", value: "Black, no sugar", category: .food),
            SeededFact(key: "Answer length", value: "Short — lead with the answer", category: .personalPreference),
            SeededFact(key: "Garage renovation", value: "Holding off until October", category: .household),
            SeededFact(
                key: "Jennifer's favourite restaurant",
                value: "Possibly the Italian place on Main",
                category: .food,
                // Deliberately low, so the screenshots show how a hedged fact is labelled (§22).
                confidence: AuraDefaults.Confidence.hedged
            )
        ]
    }

    private static var seededMessages: [MessageDraft] {
        let start = Date().addingTimeInterval(-600)
        return [
            MessageDraft(role: .user, content: "Remember that I'm saving the garage renovation until October.", createdAt: start),
            MessageDraft(
                role: .assistant,
                content: "Got it. You're holding off on the garage renovation until October.",
                providerIdentifier: LanguageModelProviderID.appleOnDevice.rawValue,
                createdAt: start.addingTimeInterval(2)
            ),
            MessageDraft(role: .user, content: "What did I decide about the garage?", createdAt: start.addingTimeInterval(300)),
            MessageDraft(
                role: .assistant,
                content: "You decided to hold off on the garage renovation until October.",
                providerIdentifier: LanguageModelProviderID.appleOnDevice.rawValue,
                createdAt: start.addingTimeInterval(302)
            )
        ]
    }
}

// MARK: - Host view

/// Renders the requested screen once the seeded environment is ready.
@MainActor
struct ScreenshotHostView: View {
    let screen: ScreenshotMode.Screen

    @State private var environment: AppEnvironment?
    @State private var ids = ScreenshotMode.SeededIDs()

    var body: some View {
        ZStack {
            // Matches the app's own background, so a screenshot taken a frame early is not a white flash.
            Color(.systemGroupedBackground).ignoresSafeArea()

            if let environment {
                content
                    .environment(environment)
                    .modelContainer(environment.persistence.container)
            }
        }
        .task {
            guard environment == nil else { return }
            let seeded = await ScreenshotMode.makeSeededEnvironment()
            ids = seeded.ids
            environment = seeded.environment
        }
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .onboardingWelcome:
            OnboardingFlowView(initialStep: .welcome)
        case .onboardingName:
            OnboardingFlowView(initialStep: .name)
        case .onboardingPersonality:
            OnboardingFlowView(initialStep: .personality)
        case .onboardingMemory:
            OnboardingFlowView(initialStep: .memory)
        case .onboardingReady:
            OnboardingFlowView(initialStep: .ready)

        case .home:
            MainTabView()
        case .conversation:
            NavigationStack { ConversationView() }
        case .conversationHistory:
            NavigationStack { ConversationHistoryView() }
        case .memoryHome:
            MemoryHomeView()
        case .aboutYou:
            NavigationStack { AboutYouView() }
        case .people:
            NavigationStack { PeopleListView() }
        case .personDetail:
            NavigationStack {
                if let personID = ids.personID {
                    PersonDetailView(personID: personID)
                } else {
                    PeopleListView()
                }
            }
        case .facts:
            // `.food` deliberately: it holds both a settled fact and the low-confidence one, so the
            // hedging label from §22 is actually visible in the screenshot. Pointing this at a category
            // with one confident fact made the screen look right while proving nothing.
            NavigationStack { ProfileFactListView(category: .food) }
        case .settings:
            SettingsHomeView()
        case .personalitySettings:
            NavigationStack { PersonalitySettingsView() }
        case .aiModel:
            NavigationStack { AIModelSettingsView() }
        case .privacy:
            NavigationStack { PrivacyDashboardView() }
        case .activity:
            ActivityHomeView()
        }
    }
}

// MARK: - Seeded system integrations (Phase 12)

extension ScreenshotMode {

    /// A calendar holding §2's scenario, so a screenshot of the schedule shows the product doing its job.
    ///
    /// A stub rather than the real service for a reason that is not just convenience: a headless screenshot
    /// run cannot answer a system permission prompt, so `EventKitCalendarService` would block forever on
    /// the first read. Dates are relative to now, so the images never go stale.
    static func seededCalendar() -> StubCalendarService {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)

        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }

        return StubCalendarService(
            events: [
                CalendarEventSnapshot(
                    id: "screenshot.dentist",
                    title: "Dentist",
                    startDate: at(0, 14),
                    endDate: at(0, 15),
                    location: "Ridgeway Dental",
                    calendarTitle: "Personal"
                ),
                CalendarEventSnapshot(
                    id: "screenshot.site",
                    title: "Site visit — Maple Street",
                    startDate: at(1, 9),
                    endDate: at(1, 11),
                    calendarTitle: "Work"
                ),
                CalendarEventSnapshot(
                    id: "screenshot.blake",
                    title: "Blake's flight home",
                    startDate: at(4, 18, 30),
                    endDate: at(4, 21),
                    calendarTitle: "Family"
                )
            ],
            reminders: [
                ReminderSnapshot(
                    id: "screenshot.tuition",
                    title: "Pay Blake's tuition",
                    dueDate: at(2, 9),
                    listTitle: "Reminders"
                ),
                ReminderSnapshot(
                    id: "screenshot.filter",
                    title: "Order air filter for the garage",
                    listTitle: "Reminders"
                )
            ]
        )
    }

    /// The people from §2's scenario, with no phone numbers — the screenshots should not show contact
    /// details AURA would only fetch when asked.
    static func seededContacts() -> StubContactLookupService {
        StubContactLookupService(results: [
            ContactSnapshot(
                id: "screenshot.blake",
                displayName: "Blake Nicol",
                nickname: "Blake",
                relations: ["son"]
            ),
            ContactSnapshot(
                id: "screenshot.priya",
                displayName: "Priya Raman",
                organizationName: "Ridgeway Dental",
                relations: ["dentist"]
            )
        ])
    }
}

#endif
