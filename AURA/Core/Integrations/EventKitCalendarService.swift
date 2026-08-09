import EventKit
import Foundation

/// `CalendarServicing` over EventKit (§37).
///
/// ### Why an actor holding one store
/// `EKEventStore` is expensive to create — it opens the calendar database — and EventKit caches against
/// it, so two stores can disagree about what exists. One store, serialised by an actor, is both cheaper
/// and the only way a create-then-read sequence is guaranteed to be consistent. Nothing here is
/// `Sendable`-hostile because no `EKEvent` ever leaves: every method returns snapshots.
///
/// ### Access is checked, never assumed
/// Every method starts by confirming access for the entity type it touches. That is not redundant with
/// `DefaultToolExecutor`'s permission gate: the gate reads `PermissionManaging`, which reads EventKit's
/// status, and between those two reads the user can revoke access in Settings. EventKit itself would then
/// return an empty array rather than an error, which would be indistinguishable from an empty calendar —
/// so AURA would tell the user they have nothing on when it simply cannot see (§78).
///
/// ### APIs verified against Apple's documentation before use
/// | API | Verified shape |
/// |---|---|
/// | `EKEventStore.requestFullAccessToEvents(completion:)` | `(Bool, (any Error)?) -> Void`; iOS 17+ |
/// | `EKEventStore.requestFullAccessToReminders(completion:)` | same shape; iOS 17+ |
/// | `EKEventStore.authorizationStatus(for:)` | `class func`, returns `EKAuthorizationStatus` |
/// | `EKAuthorizationStatus` | `.fullAccess`, `.writeOnly`, `.denied`, `.restricted`, `.notDetermined` |
/// | `predicateForEvents(withStart:end:calendars:)` | `calendars: [EKCalendar]?` |
/// | `events(matching:)` | synchronous, returns `[EKEvent]` |
/// | `predicateForIncompleteReminders(withDueDateStarting:ending:calendars:)` | both dates optional |
/// | `fetchReminders(matching:completion:)` | completion takes `[EKReminder]?`; returns a cancel token |
/// | `save(_:span:commit:)` / `save(_:commit:)` | events take a span, reminders do not |
/// | `EKCalendarItem.title` | `String!` — implicitly unwrapped, so treated as optional below |
/// | `EKEvent.startDate` / `.endDate` | `Date!` — same |
/// | `EKReminder.dueDateComponents` | `DateComponents?`, not a `Date` |
actor EventKitCalendarService: CalendarServicing {

    private let store: EKEventStore

    /// How long an event runs when the model did not say.
    ///
    /// An hour, and it is a constant here rather than a guess inside a tool so the one place that invents
    /// a duration is visible and the tool can tell the user what it assumed.
    static let defaultEventDuration: TimeInterval = 60 * 60

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    // MARK: - Events

    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        try requireReadAccess(to: .event, permission: .calendar)

        // EventKit rejects an inverted range with an exception rather than an error, so it is normalised
        // instead of trusted. A model producing end-before-start is common enough to plan for.
        let (from, to) = Self.orderedRange(start, end)

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .map(Self.snapshot(from:))
            .sorted { $0.startDate < $1.startDate }
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        try await requireWriteAccess(to: .event, permission: .calendar)

        guard let calendar = store.defaultCalendarForNewEvents else {
            // Reachable in practice: a device with every calendar disabled, or reminders-only access.
            throw AuraError.toolFailed(
                toolName: "create_calendar_event",
                reason: "there's no calendar set up on this device to add it to"
            )
        }

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.startDate
        event.endDate = draft.endDate
            ?? draft.startDate.addingTimeInterval(Self.defaultEventDuration)
        event.isAllDay = draft.isAllDay
        event.location = draft.location
        event.notes = draft.notes

        do {
            // `.thisEvent` because nothing here creates a recurring event, so there is no series for the
            // span to mean anything else about.
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AuraError.toolFailed(
                toolName: "create_calendar_event",
                reason: error.localizedDescription
            )
        }

        // Read back from the saved object rather than echoing the draft: EventKit adjusts an all-day
        // event's dates, and reporting what was asked for instead of what exists is exactly the §78
        // failure this codebase keeps guarding against.
        return Self.snapshot(from: event)
    }

    // MARK: - Reminders

    func reminders(
        from start: Date?,
        to end: Date?,
        includeUndated: Bool
    ) async throws -> [ReminderSnapshot] {
        try requireReadAccess(to: .reminder, permission: .reminders)

        // Fetched with no bounds and filtered in Swift, because EventKit's predicate excludes undated
        // reminders entirely when either bound is set — and "what do I need to do?" has to be able to
        // include them.
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: nil
        )
        let fetched = await withCheckedContinuation { continuation in
            // The return value is a cancel token, deliberately discarded: there is nothing to cancel this
            // from, and holding it would suggest otherwise.
            _ = store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        return fetched
            .map(Self.snapshot(from:))
            .filter { Self.qualifies($0, from: start, to: end, includeUndated: includeUndated) }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderSnapshot {
        try await requireWriteAccess(to: .reminder, permission: .reminders)

        guard let list = store.defaultCalendarForNewReminders() else {
            throw AuraError.toolFailed(
                toolName: "create_reminder",
                reason: "there's no reminders list set up on this device to add it to"
            )
        }

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = draft.title
        reminder.notes = draft.notes
        if let dueDate = draft.dueDate {
            reminder.dueDateComponents = Self.dueDateComponents(from: dueDate)
        }

        do {
            // No span: a reminder is not a series, which is why EventKit gives reminders their own
            // two-argument `save`.
            try store.save(reminder, commit: true)
        } catch {
            throw AuraError.toolFailed(toolName: "create_reminder", reason: error.localizedDescription)
        }

        return Self.snapshot(from: reminder)
    }

    // MARK: - Access

    /// Confirms read access, or says which permission is missing.
    ///
    /// Separate from the write check because `.writeOnly` is a real state EventKit can be in: the user
    /// granted "add to calendar" but not "see my calendar". Treating that as read access would return an
    /// empty schedule and let AURA say the day is clear.
    private func requireReadAccess(to entity: EKEntityType, permission: AuraPermission) throws {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess:
            return
        case .writeOnly, .denied, .restricted, .notDetermined:
            throw AuraError.permissionDenied(permission)
        @unknown default:
            // A future status must fail closed. Assuming access and getting an empty array back is the one
            // outcome that would make AURA lie about the user's day.
            throw AuraError.permissionDenied(permission)
        }
    }

    /// Confirms write access, requesting it once if it has never been asked for.
    ///
    /// Requested here rather than only in `PermissionManaging` because this is the moment it is needed and
    /// the moment the user's intent is clear. iOS shows nothing on a second ask, so a denied state is
    /// reported rather than re-requested.
    private func requireWriteAccess(to entity: EKEntityType, permission: AuraPermission) async throws {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            let granted = await Self.requestAccess(to: entity, in: store)
            guard granted else { throw AuraError.permissionDenied(permission) }
        case .denied, .restricted:
            throw AuraError.permissionDenied(permission)
        @unknown default:
            throw AuraError.permissionDenied(permission)
        }
    }

    /// Bridges EventKit's completion-handler request onto `async`.
    ///
    /// Written out rather than relying on the compiler's generated `async` overload, because the
    /// documented API is the completion-handler form and this is the shape that is certain to exist. An
    /// error is folded into `false`: from the caller's point of view "it threw" and "they said no" both
    /// mean AURA may not proceed.
    private static func requestAccess(to entity: EKEntityType, in store: EKEventStore) async -> Bool {
        await withCheckedContinuation { continuation in
            let handler: (Bool, (any Error)?) -> Void = { granted, error in
                if let error {
                    AuraLog.permissions.error(
                        "EventKit access request failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
                continuation.resume(returning: granted)
            }
            switch entity {
            case .event:
                store.requestFullAccessToEvents(completion: handler)
            case .reminder:
                store.requestFullAccessToReminders(completion: handler)
            @unknown default:
                continuation.resume(returning: false)
            }
        }
    }

    // MARK: - Pure helpers

    /// Puts a range the right way round.
    ///
    /// `static` and pure because EventKit throws an Objective-C exception — not a Swift error — on an
    /// inverted range, and an exception cannot be caught. This has to be right before the call, so it is
    /// tested separately from anything needing a calendar.
    static func orderedRange(_ start: Date, _ end: Date) -> (Date, Date) {
        start <= end ? (start, end) : (end, start)
    }

    /// Whether a reminder falls in the asked-for window.
    ///
    /// `static` and pure so the undated rule — the one that decides whether a two-hundred-item
    /// someday list floods every answer — is pinned by a test.
    static func qualifies(
        _ reminder: ReminderSnapshot,
        from start: Date?,
        to end: Date?,
        includeUndated: Bool
    ) -> Bool {
        guard !reminder.isCompleted else { return false }
        guard let due = reminder.dueDate else { return includeUndated }
        if let start, due < start { return false }
        if let end, due > end { return false }
        return true
    }

    /// The components EventKit needs for a reminder due date.
    ///
    /// A reminder's due date is `DateComponents`, not a `Date`, and which components are present is what
    /// decides whether iOS treats it as "on this day" or "at this time". Year through minute is included
    /// so a time the user gave is honoured; seconds are not, because no reminder is due at 14:32:07.
    static func dueDateComponents(from date: Date, calendar: Calendar = .current) -> DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// EventKit's `title` and dates are implicitly-unwrapped optionals, so they are unwrapped explicitly
    /// here. An untitled event is real — iOS shows it as "New Event" — and force-unwrapping one would
    /// crash on a calendar AURA did not create.
    private static func snapshot(from event: EKEvent) -> CalendarEventSnapshot {
        let start = event.startDate ?? Date()
        return CalendarEventSnapshot(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled event",
            startDate: start,
            endDate: event.endDate ?? start.addingTimeInterval(defaultEventDuration),
            isAllDay: event.isAllDay,
            location: event.location,
            calendarTitle: event.calendar?.title ?? ""
        )
    }

    /// Resolves a reminder's due date from its components.
    ///
    /// `DateComponents.date` returns `nil` unless the components carry a `calendar`, and EventKit does not
    /// promise to attach one. Falling back to the current calendar is what the user means by "due Friday";
    /// without the fallback a dated reminder would silently read as undated and be filtered out of "what's
    /// due today".
    static func dueDate(from components: DateComponents?, calendar: Calendar = .current) -> Date? {
        guard let components else { return nil }
        if let date = components.date { return date }
        return calendar.date(from: components)
    }

    private static func snapshot(from reminder: EKReminder) -> ReminderSnapshot {
        ReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "Untitled reminder",
            dueDate: dueDate(from: reminder.dueDateComponents),
            isCompleted: reminder.isCompleted,
            listTitle: reminder.calendar?.title ?? ""
        )
    }
}
