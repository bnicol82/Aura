import Contacts
import EventKit
import Foundation
import Testing

@testable import AURA

/// Calendar, reminders and contacts (§37).
///
/// ### What these tests can and cannot establish
/// A simulator has no calendar data and grants no real authorization, so nothing here proves AURA can read
/// a real calendar. What is testable is everything that decides *what the user is told*: the date ranges, the
/// wording, the honest empty cases, the permission mapping, and the privacy rule about contact details. Those
/// are where this feature can mislead someone, and they need no device.
@Suite("System tools", .timeLimit(.minutes(1)))
struct SystemToolTests {

    /// Noon on a fixed Friday, so nothing here depends on when the suite runs.
    private static let now = Date(timeIntervalSince1970: 1_772_884_800)

    private static func arguments(
        _ values: [String: JSONValue],
        for tool: any AssistantTool
    ) -> ToolArguments {
        ToolArguments(toolName: tool.name, values: values)
    }

    private static var context: ToolExecutionContext {
        ToolExecutionContext(userExplicitlyRequested: true, now: now)
    }

    // MARK: - Ranges

    @Test("A read with no dates covers today onwards, not an arbitrary instant")
    func defaultRangeStartsAtTodayStart() {
        // Starting at "now" would miss an event that began this morning and is still running, which is
        // exactly what someone asking "what's on today" wants to know about.
        let (start, end) = ScheduleFormatting.range(start: nil, end: nil, now: Self.now)
        #expect(start == Calendar.current.startOfDay(for: Self.now))
        #expect(
            Calendar.current.dateComponents([.day], from: start, to: end).day
                == ScheduleFormatting.defaultLookaheadDays
        )
    }

    @Test("A backwards range is swapped rather than refused")
    func backwardsRangeIsSwapped() {
        // A model producing end-before-start is a formatting slip, not a reason to refuse the question.
        let later = Self.now.addingTimeInterval(86_400)
        let (start, end) = ScheduleFormatting.range(start: later, end: Self.now, now: Self.now)
        #expect(start == Self.now)
        #expect(end == later)
    }

    @Test("EventKit is never handed an inverted range")
    func eventKitRangeIsOrdered() {
        // EventKit raises an Objective-C exception on an inverted range, and an exception cannot be caught
        // in Swift — so this has to be right before the call, not handled after it.
        let later = Self.now.addingTimeInterval(3600)
        #expect(EventKitCalendarService.orderedRange(later, Self.now) == (Self.now, later))
        #expect(EventKitCalendarService.orderedRange(Self.now, later) == (Self.now, later))
    }

    // MARK: - Wording

    @Test("A day is named absolutely, with relative wording only where it is unambiguous")
    func dayLabels() {
        func label(daysFromNow: Int) -> String {
            let date = Calendar.current.date(byAdding: .day, value: daysFromNow, to: Self.now)!
            return ScheduleFormatting.dayLabel(for: date, now: Self.now)
        }
        #expect(label(daysFromNow: 0) == "today")
        #expect(label(daysFromNow: 1) == "tomorrow")
        #expect(label(daysFromNow: -1) == "yesterday")
        // Inside the week a weekday name is unambiguous, and carries no date.
        let nearby = label(daysFromNow: 3)
        #expect(nearby != "today" && nearby != "tomorrow")
        #expect(nearby.rangeOfCharacter(from: .decimalDigits) == nil)
        // Beyond it, a bare weekday would be a guess about which one, so the date is included.
        #expect(label(daysFromNow: 20).rangeOfCharacter(from: .decimalDigits) != nil)
    }

    @Test("An event is described with its date, not just its time")
    func eventDescriptionCarriesTheDay() {
        // A model told only "1pm" and answering three turns later has no way to know which day was meant.
        let event = CalendarEventSnapshot(
            id: "1",
            title: "Dentist",
            startDate: Self.now,
            endDate: Self.now.addingTimeInterval(3600),
            location: "Ridgeway Dental"
        )
        let text = ScheduleFormatting.describe(event, now: Self.now)
        #expect(text.contains("Dentist"))
        #expect(text.contains("today"))
        #expect(text.contains("Ridgeway Dental"))
    }

    @Test("An undated reminder says so rather than being rendered bare")
    func undatedReminderSaysSo() {
        // Rendered without a date at all, the model reads it as due today.
        let reminder = ReminderSnapshot(id: "1", title: "Order air filter")
        #expect(ScheduleFormatting.describe(reminder, now: Self.now).contains("no date"))
    }

    // MARK: - Reading the calendar

    @Test("Events in the window are returned, and ones outside it are not")
    func readsOnlyTheWindow() async throws {
        let inside = CalendarEventSnapshot(
            id: "in", title: "Dentist",
            startDate: Self.now, endDate: Self.now.addingTimeInterval(3600)
        )
        let outside = CalendarEventSnapshot(
            id: "out", title: "Next month",
            startDate: Self.now.addingTimeInterval(86_400 * 40),
            endDate: Self.now.addingTimeInterval(86_400 * 40 + 3600)
        )
        let tool = ReadCalendarTool(calendarService: StubCalendarService(events: [inside, outside]))

        let result = try await tool.execute(
            arguments: Self.arguments([:], for: tool),
            context: Self.context
        )
        #expect(result.modelFacingText.contains("Dentist"))
        #expect(!result.modelFacingText.contains("Next month"))
        #expect(result.didMutateData == false)
    }

    @Test("An empty calendar is reported as readable and empty, not as a shrug")
    func emptyCalendarIsExplicit() async throws {
        // The difference that matters: "nothing is scheduled" must not be reachable from "I couldn't see
        // your calendar", or AURA tells someone their day is clear when it simply cannot look (§78).
        let tool = ReadCalendarTool(calendarService: StubCalendarService())
        let result = try await tool.execute(
            arguments: Self.arguments([:], for: tool),
            context: Self.context
        )
        #expect(result.modelFacingText.contains("readable and it is empty"))
    }

    @Test("A calendar AURA cannot read produces an error, never an empty schedule")
    func unreadableCalendarThrows() async throws {
        let tool = ReadCalendarTool(
            calendarService: StubCalendarService(failure: .permissionDenied(.calendar))
        )
        await #expect(throws: AuraError.self) {
            try await tool.execute(arguments: Self.arguments([:], for: tool), context: Self.context)
        }
    }

    // MARK: - Creating

    @Test("Creating an event reports what was saved, and says when it assumed a duration")
    func createEventReportsAssumptions() async throws {
        // The assumed end time is AURA's invention, and the user hearing about it is the difference
        // between a helpful default and a silent one.
        let tool = CreateCalendarEventTool(calendarService: StubCalendarService())
        let result = try await tool.execute(
            arguments: Self.arguments(
                ["title": .string("Site visit"), "start": .string("2026-03-13T09:00:00Z")],
                for: tool
            ),
            context: Self.context
        )
        #expect(result.didMutateData)
        #expect(result.modelFacingText.contains("Site visit"))
        #expect(result.modelFacingText.contains("one hour long"))
    }

    @Test("An event created with an explicit end says nothing about assuming one")
    func explicitEndMakesNoClaim() async throws {
        let tool = CreateCalendarEventTool(calendarService: StubCalendarService())
        let result = try await tool.execute(
            arguments: Self.arguments(
                [
                    "title": .string("Site visit"),
                    "start": .string("2026-03-13T09:00:00Z"),
                    "end": .string("2026-03-13T11:00:00Z")
                ],
                for: tool
            ),
            context: Self.context
        )
        #expect(!result.modelFacingText.contains("one hour long"))
    }

    @Test("A created event is findable afterwards")
    func createThenRead() async throws {
        // End to end through one service, which is the only way to catch a create that reports success and
        // writes nothing.
        let service = StubCalendarService()
        let create = CreateCalendarEventTool(calendarService: service)
        _ = try await create.execute(
            arguments: Self.arguments(
                ["title": .string("Dentist"), "start": .string("2026-03-13T14:00:00Z")],
                for: create
            ),
            context: Self.context
        )

        let read = ReadCalendarTool(calendarService: service)
        let found = try await read.execute(
            arguments: Self.arguments(["start": .string("2026-03-13"), "end": .string("2026-03-14")], for: read),
            context: Self.context
        )
        #expect(found.modelFacingText.contains("Dentist"))
    }

    @Test("Creating an event without a title is an argument error, not an untitled event")
    func createEventNeedsATitle() async throws {
        let tool = CreateCalendarEventTool(calendarService: StubCalendarService())
        await #expect(throws: AuraError.self) {
            try await tool.execute(
                arguments: Self.arguments(["start": .string("2026-03-13T09:00:00Z")], for: tool),
                context: Self.context
            )
        }
    }

    @Test("The confirmation prompt names the time, which is the thing worth checking")
    func eventPromptNamesTheTime() {
        let tool = CreateCalendarEventTool(calendarService: StubCalendarService())
        let prompt = tool.confirmationPrompt(
            for: Self.arguments(
                ["title": .string("Dentist"), "start": .string("2026-03-13T14:00:00Z")],
                for: tool
            )
        )
        #expect(prompt.contains("Dentist"))
        #expect(prompt.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    // MARK: - Reminders

    @Test("A reminder with no date is created without inventing one")
    func reminderWithoutADate() async throws {
        let tool = CreateReminderTool(calendarService: StubCalendarService())
        let result = try await tool.execute(
            arguments: Self.arguments(["title": .string("Order air filter")], for: tool),
            context: Self.context
        )
        #expect(result.modelFacingText.contains("no due date"))
        #expect(result.didMutateData)
    }

    @Test("Undated reminders are excluded unless asked for, and the difference is stated")
    func undatedRemindersAreOptIn() async throws {
        // An unbounded someday-list would otherwise flood every "what's due today", and the model reading
        // an empty result must not conclude there is nothing to do.
        let service = StubCalendarService(reminders: [
            ReminderSnapshot(id: "1", title: "Someday thing")
        ])
        let tool = ReadRemindersTool(calendarService: service)

        let excluded = try await tool.execute(
            arguments: Self.arguments([:], for: tool),
            context: Self.context
        )
        #expect(!excluded.modelFacingText.contains("Someday thing"))
        #expect(excluded.modelFacingText.contains("does not mean there is nothing to do"))

        let included = try await tool.execute(
            arguments: Self.arguments(["include_undated": .bool(true)], for: tool),
            context: Self.context
        )
        #expect(included.modelFacingText.contains("Someday thing"))
    }

    @Test("A completed reminder is never returned")
    func completedRemindersAreHidden() {
        let done = ReminderSnapshot(id: "1", title: "Done", dueDate: Self.now, isCompleted: true)
        #expect(!EventKitCalendarService.qualifies(done, from: nil, to: nil, includeUndated: true))

        let open = ReminderSnapshot(id: "2", title: "Open", dueDate: Self.now)
        #expect(EventKitCalendarService.qualifies(open, from: nil, to: nil, includeUndated: false))
    }

    @Test("A reminder due date keeps the time the user gave")
    func dueDateComponentsKeepTheTime() throws {
        // Reminders take `DateComponents`, and which components are present is what decides whether iOS
        // treats it as "that day" or "at that time". Dropping the hour would silently lose the alarm.
        let components = EventKitCalendarService.dueDateComponents(from: Self.now)
        #expect(components.year != nil)
        #expect(components.hour != nil)
        #expect(components.minute != nil)
        #expect(components.second == nil)
    }

    @Test("A due date resolves even when EventKit attaches no calendar to the components")
    func dueDateSurvivesMissingCalendar() throws {
        // `DateComponents.date` returns nil without a calendar, and EventKit does not promise to attach
        // one. Without the fallback a dated reminder reads as undated and gets filtered out.
        var bare = DateComponents()
        bare.year = 2026
        bare.month = 3
        bare.day = 13
        bare.hour = 9
        #expect(bare.date == nil)
        #expect(EventKitCalendarService.dueDate(from: bare) != nil)
        #expect(EventKitCalendarService.dueDate(from: nil) == nil)
    }

    // MARK: - Contacts

    @Test("Contact details are withheld unless the tool was asked for them")
    func contactDetailsAreOptIn() async throws {
        // §28: a request gets what it needs. "Who is Priya?" does not need her phone number, and the keys
        // are genuinely not fetched rather than fetched and dropped.
        func fetchedKeys(details: Bool) -> [String] {
            SystemContactLookupService.keys(includingReachableDetails: details).map { String(describing: $0) }
        }
        #expect(!fetchedKeys(details: false).contains(CNContactPhoneNumbersKey))
        #expect(!fetchedKeys(details: false).contains(CNContactEmailAddressesKey))
        #expect(fetchedKeys(details: true).contains(CNContactPhoneNumbersKey))

        let service = StubContactLookupService(results: [
            ContactSnapshot(
                id: "1",
                displayName: "Priya Raman",
                relations: ["dentist"],
                phoneNumbers: ["+441234567890"]
            )
        ])
        let tool = LookUpContactTool(contactService: service)

        let withoutDetails = try await tool.execute(
            arguments: Self.arguments(["name": .string("Priya")], for: tool),
            context: Self.context
        )
        #expect(withoutDetails.modelFacingText.contains("Priya Raman"))
        #expect(withoutDetails.modelFacingText.contains("dentist"))
        #expect(!withoutDetails.modelFacingText.contains("441234567890"))
        // And the model is told the absence means nothing, so it does not report she has no number.
        #expect(withoutDetails.modelFacingText.contains("were not looked up"))

        let withDetails = try await tool.execute(
            arguments: Self.arguments(
                ["name": .string("Priya"), "include_contact_details": .bool(true)],
                for: tool
            ),
            context: Self.context
        )
        #expect(withDetails.modelFacingText.contains("441234567890"))
    }

    @Test("Several matches tell the model to ask rather than pick")
    func ambiguousLookupAsks() {
        let text = LookUpContactTool.render(
            [
                ContactSnapshot(id: "1", displayName: "John Smith"),
                ContactSnapshot(id: "2", displayName: "John Doe")
            ],
            query: "John",
            includedDetails: false
        )
        #expect(text.contains("Ask the user which one"))
    }

    @Test("No match allows for partial contact access rather than asserting nobody exists")
    func noContactMatchIsHonest() async throws {
        // iOS 18 lets the user share a subset of their contacts. "No such person" would be wrong in that
        // case, not merely unhelpful.
        let tool = LookUpContactTool(contactService: StubContactLookupService())
        let result = try await tool.execute(
            arguments: Self.arguments(["name": .string("Nobody")], for: tool),
            context: Self.context
        )
        #expect(result.modelFacingText.contains("only shared some"))
        #expect(result.modelFacingText.contains("Do not guess"))
    }

    @Test("A contact with no name is described as unnamed rather than as an empty string")
    func unnamedContact() {
        #expect(
            SystemContactLookupService.displayName(formatted: "", nickname: "", organization: "")
                == "an unnamed contact"
        )
        #expect(
            SystemContactLookupService.displayName(formatted: nil, nickname: "", organization: "Acme Ltd")
                == "Acme Ltd"
        )
        #expect(
            SystemContactLookupService.displayName(formatted: "Priya Raman", nickname: "P", organization: "")
                == "Priya Raman"
        )
    }

    // MARK: - Permissions and gating

    @Test("Write-only calendar access is partial, not full")
    func writeOnlyIsNotFullAccess() {
        // Reported as `.limited` rather than `.authorized` or `.denied`, because both of those are lies:
        // AURA really can add an event, and really cannot read one.
        #expect(SystemPermissionManager.eventKitStatus(.writeOnly) == .limited)
        #expect(SystemPermissionManager.eventKitStatus(.fullAccess) == .authorized)
        #expect(SystemPermissionManager.eventKitStatus(.denied) == .denied)
        #expect(SystemPermissionManager.eventKitStatus(.notDetermined) == .notDetermined)
        #expect(SystemPermissionManager.eventKitStatus(.restricted) == .restricted)
    }

    @Test("Limited contact access is usable, because a subset is still something")
    func limitedContactsIsUsable() {
        // Unlike write-only calendar access, a limited address book can genuinely answer questions — it
        // just cannot prove someone is absent, which is why the no-match wording says so.
        #expect(SystemPermissionManager.contactsStatus(.limited) == .limited)
        #expect(SystemPermissionManager.contactsStatus(.limited).isUsable)
        #expect(SystemPermissionManager.contactsStatus(.authorized) == .authorized)
        #expect(SystemPermissionManager.contactsStatus(.denied) == .denied)
    }

    @Test("Each system tool declares the permission it needs")
    func toolsDeclareTheirPermissions() {
        // What makes the withholding work: a tool that forgot to declare its permission would be offered
        // to the model and then fail, which is the promise-then-refuse pattern §78 rules out.
        let calendarService = StubCalendarService()
        #expect(ReadCalendarTool(calendarService: calendarService).requiredPermissions == [.calendar])
        #expect(CreateCalendarEventTool(calendarService: calendarService).requiredPermissions == [.calendar])
        #expect(ReadRemindersTool(calendarService: calendarService).requiredPermissions == [.reminders])
        #expect(CreateReminderTool(calendarService: calendarService).requiredPermissions == [.reminders])
        #expect(
            LookUpContactTool(contactService: StubContactLookupService()).requiredPermissions == [.contacts]
        )
    }

    @Test("Reads never confirm; writes confirm when the model decided on its own")
    func riskTiers() {
        let service = StubCalendarService()
        let modelDecided = ToolExecutionContext(userExplicitlyRequested: false)
        let userAsked = ToolExecutionContext(userExplicitlyRequested: true)

        #expect(!ReadCalendarTool(calendarService: service).requiresConfirmation(context: modelDecided))
        #expect(!ReadRemindersTool(calendarService: service).requiresConfirmation(context: modelDecided))

        let create = CreateCalendarEventTool(calendarService: service)
        #expect(create.requiresConfirmation(context: modelDecided))
        #expect(!create.requiresConfirmation(context: userAsked))

        let remind = CreateReminderTool(calendarService: service)
        #expect(remind.requiresConfirmation(context: modelDecided))
        #expect(!remind.requiresConfirmation(context: userAsked))
    }

    @Test("A system tool is withheld from the model until its permission is granted")
    func toolsAreWithheldWithoutPermission() async throws {
        // The end-to-end version of the two tests above, through the executor that actually decides.
        let registry = ToolRegistry(tools: [
            SearchMemoryTool(memoryStore: SwiftDataMemoryStore(
                modelContainer: try PersistenceController.inMemory().container
            )),
            ReadCalendarTool(calendarService: StubCalendarService())
        ])
        let executor = DefaultToolExecutor(
            registry: registry,
            permissions: StubPermissionManager.denyingEverything(),
            networkMonitor: StubNetworkMonitor.online
        )
        #expect(await executor.availableToolDefinitions().map(\.name) == ["search_memory"])
    }

    @Test("Write-only access offers the create tool and withholds the read tool")
    func partialAccessSplitsTheCalendarTools() async throws {
        // This is the whole point of `requiresFullPermissionAccess`. Under write-only access AURA can
        // genuinely add an event, so offering that is honest — and it genuinely cannot read, so offering
        // `read_calendar` would be a promise it would then refuse.
        let service = StubCalendarService()
        let executor = DefaultToolExecutor(
            registry: ToolRegistry(tools: [
                ReadCalendarTool(calendarService: service),
                CreateCalendarEventTool(calendarService: service)
            ]),
            permissions: StubPermissionManager(statuses: [.calendar: .limited]),
            networkMonitor: StubNetworkMonitor.online
        )

        #expect(await executor.availableToolDefinitions().map(\.name) == ["create_calendar_event"])

        // And the gate agrees with the offer, rather than the two disagreeing.
        await #expect(throws: AuraError.self) {
            try await executor.execute(
                toolNamed: "read_calendar",
                arguments: [:],
                context: Self.context
            )
        }
    }

    @Test("Full access offers both")
    func fullAccessOffersBoth() async throws {
        let service = StubCalendarService()
        let executor = DefaultToolExecutor(
            registry: ToolRegistry(tools: [
                ReadCalendarTool(calendarService: service),
                CreateCalendarEventTool(calendarService: service)
            ]),
            permissions: StubPermissionManager(statuses: [.calendar: .authorized]),
            networkMonitor: StubNetworkMonitor.online
        )
        #expect(
            await executor.availableToolDefinitions().map(\.name).sorted()
                == ["create_calendar_event", "read_calendar"]
        )
    }
}
