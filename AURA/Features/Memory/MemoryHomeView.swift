import SwiftUI

/// The memory tab (§44).
///
/// Titled after the user's assistant, because "What Nova Knows About You" is a different promise from
/// "Memory Settings" — it tells the user this screen is the truth about what is stored, and that they
/// can change any of it.
///
/// In Phase 1 the profile sections are live and editable; the sections that depend on automatic
/// extraction say plainly that they are not filling up yet.
@MainActor
struct MemoryHomeView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            List {
                summarySection
                aboutYouSection
                peopleSection
                knowledgeSections
                memorySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("What \(environment.assistantName) Knows")
            .navigationDestination(for: MemoryRoute.self) { route in
                switch route {
                case .aboutYou:
                    AboutYouView()
                case .people:
                    PeopleListView()
                case .facts(let category):
                    ProfileFactListView(category: category)
                }
            }
            .refreshable {
                await environment.refreshUserProfile()
            }
        }
    }

    // MARK: - Sections

    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(summaryHeadline)
                    .font(.headline)
                Text("Everything here is yours to edit or delete. Nothing leaves this iPhone.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
    }

    private var aboutYouSection: some View {
        Section("About you") {
            NavigationLink(value: MemoryRoute.aboutYou) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your details")
                        Text(aboutYouSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.text.rectangle")
                }
            }
        }
    }

    private var peopleSection: some View {
        Section("People") {
            NavigationLink(value: MemoryRoute.people) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Important people")
                        Text(peopleSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "person.2")
                }
            }
        }
    }

    /// Category groups over `ProfileFact`, which is how the specification's many preference buckets
    /// are expressed without twenty-four columns on `UserProfile`.
    private var knowledgeSections: some View {
        Section("What I've learned") {
            ForEach(MemoryHomeView.browsableCategories, id: \.self) { category in
                NavigationLink(value: MemoryRoute.facts(category)) {
                    Label {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            Text("\(factCount(for: category))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    } icon: {
                        Image(systemName: category.symbolName)
                    }
                }
            }
        }
    }

    private var memorySection: some View {
        Section("Conversation memory") {
            PendingFeatureNotice(stage: FeatureFlags.memory, symbolName: "brain")
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
        }
    }

    // MARK: - Derived

    /// Categories offered as browsable groups.
    ///
    /// A curated list rather than `MemoryCategory.allCases`: `.temporaryContext` and `.other` are
    /// mechanics, not something a person wants a row for, and `.health`/`.finance` are reached through
    /// their own facts rather than advertised as headings.
    static let browsableCategories: [MemoryCategory] = [
        .personalPreference,
        .goal,
        .routine,
        .work,
        .education,
        .travel,
        .food,
        .sports,
        .entertainment,
        .technology,
        .household,
        .importantDate,
        .place
    ]

    private var summaryHeadline: String {
        let profile = environment.userProfile
        if profile.isEssentiallyEmpty {
            return "I don't know anything about you yet."
        }
        let count = profile.knownItemCount
        return "\(count) \(count == 1 ? "thing" : "things") I know about you."
    }

    private var aboutYouSubtitle: String {
        let profile = environment.userProfile
        if let name = profile.preferredName {
            return "I call you \(name)."
        }
        return "You haven't told me what to call you."
    }

    private var peopleSubtitle: String {
        let count = environment.userProfile.people.count
        guard count > 0 else { return "No one added yet." }
        let names = environment.userProfile.people.prefix(3).map(\.displayName).joined(separator: ", ")
        return count <= 3 ? names : "\(names), and \(count - 3) more"
    }

    private func factCount(for category: MemoryCategory) -> Int {
        environment.userProfile.facts.filter { $0.category == category }.count
    }
}

enum MemoryRoute: Hashable {
    case aboutYou
    case people
    case facts(MemoryCategory)
}

#Preview {
    MemoryHomeView()
        .environment(AppEnvironment.preview())
}
