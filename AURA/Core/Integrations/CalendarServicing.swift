import Foundation

/// One calendar event, as everything above EventKit sees it.
///
/// A `Sendable` value rather than an `EKEvent` for the same reason SwiftData models never leave their
/// actor: `EKEvent` is a mutable reference tied to an `EKEventStore`, and passing one across an
/// isolation boundary is how you get a crash that reproduces once a week. Snapshots in, snapshots out.
struct CalendarEventSnapshot: Sendable, Equatable, Identifiable, Hashable {
    /// EventKit's `eventIdentifier`. Stable enough to reference in a follow-up, not stable enough to
    /// persist as a foreign key — a synced event can be re-created with a new one.
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var location: String?
    var calendarTitle: String

    init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool = false,
        location: String? = nil,
        calendarTitle: String = ""
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.calendarTitle = calendarTitle
    }
}

/// An event about to be created.
struct CalendarEventDraft: Sendable, Equatable {
    var title: String
    var startDate: Date
    /// `nil` means "use the default duration", which the service decides — a model asked for "lunch at
    /// one" has not been told to invent an end time, and guessing one in the tool would hide that.
    var endDate: Date?
    var isAllDay: Bool
    var location: String?
    var notes: String?

    init(
        title: String,
        startDate: Date,
        endDate: Date? = nil,
        isAllDay: Bool = false,
        location: String? = nil,
        notes: String? = nil
    ) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
    }
}

/// One reminder.
struct ReminderSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    /// `nil` for a reminder with no date — which is most of them, and the reason this is not a `Date`.
    var dueDate: Date?
    var isCompleted: Bool
    var listTitle: String

    init(
        id: String,
        title: String,
        dueDate: Date? = nil,
        isCompleted: Bool = false,
        listTitle: String = ""
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.isCompleted = isCompleted
        self.listTitle = listTitle
    }
}

/// A reminder about to be created.
struct ReminderDraft: Sendable, Equatable {
    var title: String
    var dueDate: Date?
    var notes: String?

    init(title: String, dueDate: Date? = nil, notes: String? = nil) {
        self.title = title
        self.dueDate = dueDate
        self.notes = notes
    }
}

/// Calendar and reminders, behind one seam (§37).
///
/// ### Why one protocol for two entity types
/// EventKit is one framework with one store and one authorization model per entity type, and a tool that
/// creates a reminder and a tool that creates an event differ only in which half they touch. Splitting
/// them would mean two actors holding two `EKEventStore`s, which is worse: the framework caches, and two
/// stores can disagree about what exists.
///
/// ### What this deliberately does not expose
/// No `EKCalendar` selection, no recurrence rules, no attendees, no alarms. Each of those is a place a
/// model can confidently produce something wrong — a weekly recurrence when the user said "next week",
/// an invitation sent to a stranger — and none is needed for the cases §37 describes. They are absent
/// rather than half-supported, so a tool cannot promise them.
protocol CalendarServicing: Sendable {

    /// Events overlapping the range, soonest first.
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot]

    /// Creates an event and returns it as saved, so the caller reports what actually exists rather than
    /// what it asked for.
    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventSnapshot

    /// Incomplete reminders due in the range, plus undated ones when `includeUndated` is set.
    ///
    /// Undated reminders are opt-in because they are unbounded: a user with two hundred someday-maybe
    /// items would otherwise get all of them every time they asked what was due today.
    func reminders(
        from start: Date?,
        to end: Date?,
        includeUndated: Bool
    ) async throws -> [ReminderSnapshot]

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderSnapshot
}

/// A fixed calendar, for tests, previews and screenshots.
///
/// An actor because creating mutates it: a test that creates an event and then reads it back is checking
/// the thing that matters, and a struct would silently drop the write.
actor StubCalendarService: CalendarServicing {

    private var storedEvents: [CalendarEventSnapshot]
    private var storedReminders: [ReminderSnapshot]
    /// Thrown by every method when set. Lets a test exercise the failure path without a real store.
    private let failure: AuraError?

    init(
        events: [CalendarEventSnapshot] = [],
        reminders: [ReminderSnapshot] = [],
        failure: AuraError? = nil
    ) {
        self.storedEvents = events
        self.storedReminders = reminders
        self.failure = failure
    }

    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        if let failure { throw failure }
        // Overlap rather than containment, matching EventKit: an event that started yesterday and runs
        // through today is on today's schedule.
        return storedEvents
            .filter { $0.startDate < end && $0.endDate > start }
            .sorted { $0.startDate < $1.startDate }
    }

    func createEvent(_ draft: CalendarEventDraft) async throws -> CalendarEventSnapshot {
        if let failure { throw failure }
        let saved = CalendarEventSnapshot(
            id: UUID().uuidString,
            title: draft.title,
            startDate: draft.startDate,
            endDate: draft.endDate ?? draft.startDate.addingTimeInterval(3600),
            isAllDay: draft.isAllDay,
            location: draft.location,
            calendarTitle: "Stub"
        )
        storedEvents.append(saved)
        return saved
    }

    func reminders(
        from start: Date?,
        to end: Date?,
        includeUndated: Bool
    ) async throws -> [ReminderSnapshot] {
        if let failure { throw failure }
        return storedReminders
            .filter { reminder in
                guard !reminder.isCompleted else { return false }
                guard let due = reminder.dueDate else { return includeUndated }
                if let start, due < start { return false }
                if let end, due > end { return false }
                return true
            }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    func createReminder(_ draft: ReminderDraft) async throws -> ReminderSnapshot {
        if let failure { throw failure }
        let saved = ReminderSnapshot(
            id: UUID().uuidString,
            title: draft.title,
            dueDate: draft.dueDate,
            isCompleted: false,
            listTitle: "Stub"
        )
        storedReminders.append(saved)
        return saved
    }
}
