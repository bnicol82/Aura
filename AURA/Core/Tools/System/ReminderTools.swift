import Foundation

/// Reads what the user still has to do (§37).
struct ReadRemindersTool: AssistantTool {

    let id = "reminders.read"
    let name = "read_reminders"

    var description: String {
        """
        Look at the user's incomplete reminders. Use this when the answer depends on what they still have \
        to do. By default this covers dated reminders in the next week; set include_undated to also get \
        the ones with no date, which can be a long list.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "start",
                description: "Earliest due date to include, ISO 8601. Omit for today.",
                type: .date,
                isRequired: false
            ),
            ToolParameter(
                name: "end",
                description: "Latest due date to include, ISO 8601. Omit to cover the following week.",
                type: .date,
                isRequired: false
            ),
            ToolParameter(
                name: "include_undated",
                description: """
                    True to include reminders with no due date. Use it when the user asks what they need \
                    to do generally, not when they ask about a specific day.
                    """,
                type: .boolean,
                isRequired: false
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .readOnly
    var requiredPermissions: Set<AuraPermission> { [.reminders] }
    /// Write-only access is not enough to read: EventKit would return an empty array, and AURA would tell
    /// the user there is nothing there rather than that it cannot look.
    var requiresFullPermissionAccess: Bool { true }

    private let calendarService: any CalendarServicing

    init(calendarService: any CalendarServicing) {
        self.calendarService = calendarService
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Checking your reminders"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let includeUndated = arguments.optionalBool("include_undated") ?? false
        let (start, end) = ScheduleFormatting.range(
            start: arguments.optionalDate("start", now: context.now),
            end: arguments.optionalDate("end", now: context.now),
            now: context.now
        )

        let reminders = try await calendarService.reminders(
            from: start,
            to: end,
            includeUndated: includeUndated
        )

        guard !reminders.isEmpty else {
            return ToolResult(
                // The distinction matters: an empty list with undated reminders excluded does not mean
                // there is nothing to do, and saying so stops the model overstating it.
                modelFacingText: includeUndated
                    ? "There are no incomplete reminders in that period. The list was readable and empty."
                    : """
                        There are no dated reminders in that period. Undated reminders were not included, \
                        so this does not mean there is nothing to do.
                        """,
                activityLabel: "Checked your reminders",
                outcomeSummary: "Nothing due",
                didMutateData: false
            )
        }

        let lines = reminders.map { "- " + ScheduleFormatting.describe($0, now: context.now) }
        return ToolResult(
            modelFacingText: """
                \(reminders.count) incomplete \(reminders.count == 1 ? "reminder" : "reminders"):
                \(lines.joined(separator: "\n"))
                """,
            activityLabel: "Checked your reminders",
            outcomeSummary: reminders.count == 1 ? "1 reminder" : "\(reminders.count) reminders",
            didMutateData: false
        )
    }
}

/// Creates a reminder (§37).
///
/// `reversible` for the same reason as a calendar event: trivially deleted, but not something the model
/// should be adding on its own initiative without saying so first.
struct CreateReminderTool: AssistantTool {

    let id = "reminders.create"
    let name = "create_reminder"

    var description: String {
        """
        Create a reminder for something the user needs to do. Use this rather than a calendar event when \
        there is a task rather than an appointment. A due date is optional — a reminder with no date is \
        normal and better than an invented one.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "title",
                description: "What to do, in the user's own words. An action, not a description.",
                type: .string,
                isRequired: true
            ),
            ToolParameter(
                name: "due",
                description: """
                    When it is due, ISO 8601, with a time if the user gave one. Omit entirely if they did \
                    not say when — do not guess a date.
                    """,
                type: .date,
                isRequired: false
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .reversible
    var requiredPermissions: Set<AuraPermission> { [.reminders] }

    private let calendarService: any CalendarServicing

    init(calendarService: any CalendarServicing) {
        self.calendarService = calendarService
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Setting a reminder"
    }

    func confirmationPrompt(for arguments: ToolArguments) -> String {
        guard let title = arguments.optionalString("title") else { return "Set a reminder?" }
        guard let due = arguments.optionalDate("due") else {
            return "Set a reminder to “\(title)”, with no date?"
        }
        return "Set a reminder to “\(title)” for "
            + "\(ScheduleFormatting.dayLabel(for: due, now: Date())) at \(ScheduleFormatting.time(due))?"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let draft = ReminderDraft(
            title: try arguments.string("title"),
            dueDate: arguments.optionalDate("due", now: context.now)
        )

        let saved = try await calendarService.createReminder(draft)

        return ToolResult(
            // Says explicitly when there is no date, so the model does not describe it as due today.
            modelFacingText: saved.dueDate == nil
                ? "Created a reminder with no due date: \(saved.title)."
                : "Created a reminder: \(ScheduleFormatting.describe(saved, now: context.now)).",
            activityLabel: "Set a reminder",
            outcomeSummary: saved.title,
            structuredResult: .object(["reminder_id": .string(saved.id)]),
            didMutateData: true
        )
    }
}
