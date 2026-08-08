import SwiftData
import SwiftUI

/// The audit trail (§45).
///
/// Reads `ActivityRecord` directly, so it needs no further work once things start writing rows. In
/// Phase 1 it is genuinely empty — no tools exist to record — and it says so rather than showing
/// invented sample rows.
@MainActor
struct ActivityHomeView: View {
    @Environment(AppEnvironment.self) private var environment

    @Query(sort: \ActivityRecord.createdAt, order: .reverse)
    private var records: [ActivityRecord]

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Activity")
        }
    }

    private var list: some View {
        List {
            // Grouped by day, which is how someone actually looks for "what did it do yesterday?".
            ForEach(groupedRecords) { group in
                Section(group.label) {
                    ForEach(group.records) { record in
                        ActivityRow(record: record.snapshot)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("Nothing yet", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("This is where I'll show you exactly what I did — every reminder created, every memory saved, every search.")
            }
            PendingFeatureNotice(stage: FeatureFlags.activityLog, symbolName: "wrench.and.screwdriver")
                .padding(.horizontal)
        }
    }

    /// A day's worth of activity.
    ///
    /// A named type rather than a tuple: Swift has no key paths into tuple elements, so `ForEach`
    /// cannot identify tuple rows.
    private struct DayGroup: Identifiable {
        let day: Date
        let label: String
        let records: [ActivityRecord]

        var id: Date { day }
    }

    /// Records bucketed by day, newest day first.
    private var groupedRecords: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { record in
            calendar.startOfDay(for: record.createdAt)
        }
        return grouped
            .sorted { $0.key > $1.key }
            .map { entry in
                DayGroup(
                    day: entry.key,
                    label: Self.dayLabel(for: entry.key, calendar: calendar),
                    records: entry.value
                )
            }
    }

    private static func dayLabel(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

@MainActor
private struct ActivityRow: View {
    let record: ActivityRecordSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.kind.symbolName)
                .font(.body)
                .foregroundStyle(record.succeeded ? Color.accentColor : Color.orange)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.title)
                    .font(.body)
                if let detail = record.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !record.succeeded {
                    Label("Didn't go through", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            Text(record.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let environment = AppEnvironment.preview()
    ActivityHomeView()
        .environment(environment)
        .modelContainer(environment.persistence.container)
}
