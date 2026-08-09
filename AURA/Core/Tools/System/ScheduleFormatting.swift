import Foundation

/// How schedule information is written for the model (§37, §78).
///
/// ### Why this is one type of pure functions
/// Every one of these decisions is a place AURA can mislead, and none of them needs a calendar database to
/// verify. An event rendered without its date lets the model say "you have lunch" about next Thursday. A
/// relative day rendered from the wrong clock says "tomorrow" about today. So the wording lives here, as
/// static pure functions with tests, rather than inline in four tools that would drift apart.
///
/// ### The rule the wording follows
/// Absolute before relative. "Thursday 13 March at 1pm" first, "tomorrow" only as an addition — because a
/// model that reads only "tomorrow" and answers three turns later has no way to know the day rolled over,
/// whereas a date is true whenever it is read.
enum ScheduleFormatting {

    /// The window a request means when it names no dates.
    ///
    /// A week, because "what's coming up" is the common question and a day is too short to answer it while
    /// a month is too much to put in a prompt (§28).
    static let defaultLookaheadDays = 7

    /// The whole of the day `date` falls in, in `calendar`'s terms.
    ///
    /// Day boundaries come from the calendar rather than arithmetic on seconds, so a request made during a
    /// daylight-saving change still covers one real day.
    static func day(containing date: Date, calendar: Calendar = .current) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (start, end)
    }

    /// The range a read request should use.
    ///
    /// Both bounds optional because a model asking "what's on today" gives neither, "after Friday" gives
    /// one, and "next week" gives two. An end before the start is swapped rather than rejected — a model
    /// getting them backwards is a formatting slip, not a reason to refuse the question.
    static func range(
        start: Date?,
        end: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let from = start ?? calendar.startOfDay(for: now)
        let to = end ?? calendar.date(byAdding: .day, value: defaultLookaheadDays, to: from)
            ?? from.addingTimeInterval(Double(defaultLookaheadDays) * 86_400)
        return to < from ? (to, from) : (from, to)
    }

    /// One event, as a line for the model.
    static func describe(
        _ event: CalendarEventSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let when = event.isAllDay
            ? "all day \(dayLabel(for: event.startDate, now: now, calendar: calendar))"
            : "\(dayLabel(for: event.startDate, now: now, calendar: calendar)) at \(time(event.startDate))"

        var line = "\(event.title) — \(when)"
        if let location = event.location, !location.isBlank {
            line += ", at \(location)"
        }
        return line
    }

    /// One reminder, as a line for the model.
    static func describe(
        _ reminder: ReminderSnapshot,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        guard let due = reminder.dueDate else {
            // Said outright rather than omitted. A reminder rendered with no date at all invites the model
            // to assume it is due today.
            return "\(reminder.title) — no date"
        }
        return "\(reminder.title) — due \(dayLabel(for: due, now: now, calendar: calendar)) at \(time(due))"
    }

    /// A day, named the way a person would name it.
    ///
    /// Relative wording only inside the window where it is unambiguous, and always alongside the weekday
    /// or date rather than instead of it.
    static func dayLabel(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0

        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6:
            // Within the week, the weekday alone is unambiguous and is how people say it.
            return date.formatted(.dateTime.weekday(.wide))
        default:
            // Outside it, the date is the only honest option: "Friday" three weeks out is a guess about
            // which Friday.
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }

    /// What the model is told when a range holds nothing.
    ///
    /// Stated flatly, because "I didn't find much" is an invitation to fill the gap, and the gap here is
    /// the user's actual schedule.
    static func emptyScheduleText(from start: Date, to end: Date, now: Date) -> String {
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end.addingTimeInterval(-1))
        let window = sameDay
            ? dayLabel(for: start, now: now)
            : "\(dayLabel(for: start, now: now)) to \(dayLabel(for: end, now: now))"
        return "Nothing is scheduled \(window). The calendar was readable and it is empty."
    }
}
