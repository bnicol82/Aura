import Foundation

/// Reads the user's schedule (§37).
///
/// `readOnly` and needs calendar access. Nothing it can do changes anything, so it never asks for
/// confirmation — the permission grant *is* the authorisation, and prompting on every read would train the
/// user to tap through prompts, which is how the confirmations that matter stop being read.
struct ReadCalendarTool: AssistantTool {

    let id = "calendar.read"
    let name = "read_calendar"

    var description: String {
        """
        Look at the user's calendar for a date range. Use this whenever the answer depends on what is \
        actually scheduled — never answer from memory of an earlier turn, because the calendar may have \
        changed. If it returns nothing, the calendar is genuinely empty for that range.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "start",
                description: """
                    First day to include, as an ISO 8601 date such as 2026-03-13. Omit for today.
                    """,
                type: .date,
                isRequired: false
            ),
            ToolParameter(
                name: "end",
                description: """
                    Last moment to include, as an ISO 8601 date. Omit to cover the following week.
                    """,
                type: .date,
                isRequired: false
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .readOnly
    var requiredPermissions: Set<AuraPermission> { [.calendar] }
    /// Write-only access is not enough to read: EventKit would return an empty array, and AURA would tell
    /// the user there is nothing there rather than that it cannot look.
    var requiresFullPermissionAccess: Bool { true }

    private let calendarService: any CalendarServicing

    init(calendarService: any CalendarServicing) {
        self.calendarService = calendarService
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Checking your calendar"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let (start, end) = ScheduleFormatting.range(
            start: arguments.optionalDate("start", now: context.now),
            end: arguments.optionalDate("end", now: context.now),
            now: context.now
        )

        let events = try await calendarService.events(from: start, to: end)

        guard !events.isEmpty else {
            return ToolResult(
                modelFacingText: ScheduleFormatting.emptyScheduleText(
                    from: start, to: end, now: context.now
                ),
                activityLabel: "Checked your calendar",
                outcomeSummary: "Nothing scheduled",
                didMutateData: false
            )
        }

        let lines = events.map { "- " + ScheduleFormatting.describe($0, now: context.now) }
        return ToolResult(
            modelFacingText: """
                \(events.count) \(events.count == 1 ? "event" : "events") on the calendar:
                \(lines.joined(separator: "\n"))
                """,
            activityLabel: "Checked your calendar",
            outcomeSummary: events.count == 1 ? "1 event" : "\(events.count) events",
            didMutateData: false
        )
    }
}

/// Adds an event to the calendar (§37).
///
/// `reversible`, so it runs without a prompt when the user asked in this turn and is confirmed when the
/// model decided on its own. Deleting an event the user did not want is a few taps; a model quietly
/// filling someone's calendar is the behaviour §34 exists to prevent.
struct CreateCalendarEventTool: AssistantTool {

    let id = "calendar.create"
    let name = "create_calendar_event"

    var description: String {
        """
        Add an event to the user's calendar. Only for things happening at a specific time. For something \
        the user needs to do rather than attend, create a reminder instead. You must have a concrete start \
        time — if the user was vague about when, ask them rather than guessing.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "title",
                description: "What the event is, in the user's own words. Short, no invented detail.",
                type: .string,
                isRequired: true
            ),
            ToolParameter(
                name: "start",
                description: """
                    When it starts, as ISO 8601 with a time: 2026-03-13T13:00:00. Resolve relative dates \
                    like "Friday" against the current date given in your context.
                    """,
                type: .date,
                isRequired: true
            ),
            ToolParameter(
                name: "end",
                description: "When it ends, ISO 8601. Omit and it will be one hour long.",
                type: .date,
                isRequired: false
            ),
            ToolParameter(
                name: "location",
                description: "Where it is, if the user said. Never guess an address.",
                type: .string,
                isRequired: false
            ),
            ToolParameter(
                name: "all_day",
                description: "True for something with no particular time, like a birthday.",
                type: .boolean,
                isRequired: false
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .reversible
    var requiredPermissions: Set<AuraPermission> { [.calendar] }

    private let calendarService: any CalendarServicing

    init(calendarService: any CalendarServicing) {
        self.calendarService = calendarService
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Adding it to your calendar"
    }

    func confirmationPrompt(for arguments: ToolArguments) -> String {
        // States what will exist, including when. A prompt saying only "Add this event?" gives the user
        // nothing to check, and the thing most worth checking is the time.
        guard let title = arguments.optionalString("title") else {
            return "Add an event to your calendar?"
        }
        guard let start = arguments.optionalDate("start") else {
            return "Add “\(title)” to your calendar?"
        }
        return "Add “\(title)” to your calendar for "
            + "\(ScheduleFormatting.dayLabel(for: start, now: Date())) at \(ScheduleFormatting.time(start))?"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let draft = CalendarEventDraft(
            title: try arguments.string("title"),
            startDate: try arguments.date("start", now: context.now),
            endDate: arguments.optionalDate("end", now: context.now),
            isAllDay: arguments.optionalBool("all_day") ?? false,
            location: arguments.optionalString("location")
        )

        let saved = try await calendarService.createEvent(draft)

        // Reported from what came back, not from the draft: EventKit adjusts all-day events, and an
        // assumed end time is something the user should hear about.
        var text = "Created a calendar event: \(ScheduleFormatting.describe(saved, now: context.now))."
        if draft.endDate == nil && !saved.isAllDay {
            text += " No end time was given, so it was made one hour long."
        }

        return ToolResult(
            modelFacingText: text,
            activityLabel: "Added to your calendar",
            outcomeSummary: saved.title,
            structuredResult: .object(["event_id": .string(saved.id)]),
            didMutateData: true
        )
    }
}
