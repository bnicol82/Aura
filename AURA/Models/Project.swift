import Foundation
import SwiftData

/// An ongoing effort the user has going: a renovation, a fantasy league, college planning (§55).
///
/// Projects exist so "What were we doing with the garage?" resolves to a coherent body of knowledge
/// instead of a keyword sweep across every memory ever stored.
@Model
final class Project {
    var id: UUID = UUID()

    var name: String = ""
    /// Rolling description of where the project stands, updated as decisions accumulate.
    var summary: String?

    var statusRaw: String = ProjectStatus.active.rawValue

    var goals: [String] = []
    var tags: [String] = []

    /// Aliases the user actually says — "the garage", "garage reno" — so retrieval can match a
    /// project without an exact name match.
    var aliases: [String] = []

    /// Flat lower-cased haystack over name, summary, goals, tags and aliases.
    var searchText: String = ""

    var relatedMemoryIDs: [UUID] = []
    var relatedPersonIDs: [UUID] = []

    var targetDate: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \AssistantTask.project)
    var tasks: [AssistantTask]?

    init(
        name: String = "",
        summary: String? = nil,
        status: ProjectStatus = .active,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.summary = summary
        self.statusRaw = status.rawValue
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.searchText = Self.searchText(name: name, summary: summary, goals: [], tags: [], aliases: [])
    }

    var status: ProjectStatus {
        get { ProjectStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var openTasks: [AssistantTask] {
        (tasks ?? []).filter { $0.status.isOutstanding }
            .sorted { lhs, rhs in
                if lhs.priority.sortWeight != rhs.priority.sortWeight {
                    return lhs.priority.sortWeight > rhs.priority.sortWeight
                }
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.createdAt < rhs.createdAt
                }
            }
    }

    var completedTasks: [AssistantTask] {
        (tasks ?? []).filter { $0.status == .completed }
    }

    /// Everything the user might call this project.
    var matchTerms: [String] {
        ([name] + aliases).filter { !$0.isEmpty }
    }

    func refreshSearchText() {
        searchText = Self.searchText(name: name, summary: summary, goals: goals, tags: tags, aliases: aliases)
    }

    private static func searchText(
        name: String,
        summary: String?,
        goals: [String],
        tags: [String],
        aliases: [String]
    ) -> String {
        ([name, summary ?? ""] + goals + tags + aliases)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
    }

    /// Compact project state for model context — name, status, where it stands, what's left.
    var contextLine: String {
        var parts: [String] = ["\(name) (\(status.displayName.lowercased()))"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        let outstanding = openTasks.prefix(4).map(\.title)
        if !outstanding.isEmpty { parts.append("still open: \(outstanding.joined(separator: ", "))") }
        return parts.joined(separator: " — ")
    }

    var snapshot: ProjectSnapshot {
        ProjectSnapshot(
            id: id,
            name: name,
            summary: summary,
            status: status,
            goals: goals,
            tags: tags,
            aliases: aliases,
            relatedMemoryIDs: relatedMemoryIDs,
            relatedPersonIDs: relatedPersonIDs,
            openTasks: openTasks.map(\.snapshot),
            completedTaskCount: completedTasks.count,
            targetDate: targetDate,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }
}

/// An obligation AURA is tracking (§56).
///
/// Distinct from a system reminder on purpose. "I need to buy an air filter" becomes an
/// `AssistantTask` — something AURA knows is outstanding. It only becomes a `UNNotificationRequest`
/// when the user asks to be reminded. `systemReminderIdentifier` records whether that happened, so
/// AURA never implies it set an alarm it did not set (§78).
@Model
final class AssistantTask {
    var id: UUID = UUID()

    var title: String = ""
    var details: String?

    var statusRaw: String = TaskStatus.open.rawValue
    var priorityRaw: String = TaskPriority.normal.rawValue

    var dueDate: Date?

    var sourceMemoryID: UUID?
    var sourceConversationID: UUID?

    /// Identifier of the notification or Reminders item actually created, if any.
    var systemReminderIdentifier: String?

    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date?

    var project: Project?

    init(
        title: String = "",
        details: String? = nil,
        status: TaskStatus = .open,
        priority: TaskPriority = .normal,
        dueDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.title = title
        self.details = details
        self.statusRaw = status.rawValue
        self.priorityRaw = priority.rawValue
        self.dueDate = dueDate
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    /// `true` when AURA actually created a system-level reminder for this.
    var hasSystemReminder: Bool { systemReminderIdentifier != nil }

    func isOverdue(at reference: Date = Date()) -> Bool {
        guard status.isOutstanding, let dueDate else { return false }
        return dueDate < reference
    }

    func markCompleted(at date: Date = Date()) {
        status = .completed
        completedAt = date
        updatedAt = date
    }

    var snapshot: AssistantTaskSnapshot {
        AssistantTaskSnapshot(
            id: id,
            title: title,
            details: details,
            status: status,
            priority: priority,
            dueDate: dueDate,
            projectID: project?.id,
            projectName: project?.name,
            sourceMemoryID: sourceMemoryID,
            sourceConversationID: sourceConversationID,
            hasSystemReminder: hasSystemReminder,
            createdAt: createdAt,
            updatedAt: updatedAt,
            completedAt: completedAt
        )
    }
}

// MARK: - Snapshots

struct AssistantTaskSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var details: String?
    var status: TaskStatus
    var priority: TaskPriority
    var dueDate: Date?
    var projectID: UUID?
    var projectName: String?
    var sourceMemoryID: UUID?
    var sourceConversationID: UUID?
    var hasSystemReminder: Bool
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String = "",
        details: String? = nil,
        status: TaskStatus = .open,
        priority: TaskPriority = .normal,
        dueDate: Date? = nil,
        projectID: UUID? = nil,
        projectName: String? = nil,
        sourceMemoryID: UUID? = nil,
        sourceConversationID: UUID? = nil,
        hasSystemReminder: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.priority = priority
        self.dueDate = dueDate
        self.projectID = projectID
        self.projectName = projectName
        self.sourceMemoryID = sourceMemoryID
        self.sourceConversationID = sourceConversationID
        self.hasSystemReminder = hasSystemReminder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

struct ProjectSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var summary: String?
    var status: ProjectStatus
    var goals: [String]
    var tags: [String]
    var aliases: [String]
    var relatedMemoryIDs: [UUID]
    var relatedPersonIDs: [UUID]
    var openTasks: [AssistantTaskSnapshot]
    var completedTaskCount: Int
    var targetDate: Date?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        summary: String? = nil,
        status: ProjectStatus = .active,
        goals: [String] = [],
        tags: [String] = [],
        aliases: [String] = [],
        relatedMemoryIDs: [UUID] = [],
        relatedPersonIDs: [UUID] = [],
        openTasks: [AssistantTaskSnapshot] = [],
        completedTaskCount: Int = 0,
        targetDate: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.status = status
        self.goals = goals
        self.tags = tags
        self.aliases = aliases
        self.relatedMemoryIDs = relatedMemoryIDs
        self.relatedPersonIDs = relatedPersonIDs
        self.openTasks = openTasks
        self.completedTaskCount = completedTaskCount
        self.targetDate = targetDate
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }

    var matchTerms: [String] { ([name] + aliases).filter { !$0.isEmpty } }

    var contextLine: String {
        var parts: [String] = ["\(name) (\(status.displayName.lowercased()))"]
        if let summary, !summary.isEmpty { parts.append(summary) }
        let outstanding = openTasks.prefix(4).map(\.title)
        if !outstanding.isEmpty { parts.append("still open: \(outstanding.joined(separator: ", "))") }
        return parts.joined(separator: " — ")
    }
}
