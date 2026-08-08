import SwiftUI

/// The people AURA knows about (§14, §44).
@MainActor
struct PeopleListView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var isAddingPerson = false
    @State private var newName = ""
    @State private var newRelationship = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            if environment.userProfile.people.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("No one yet", systemImage: "person.2")
                    } description: {
                        Text("Add the people who come up often, and I'll stop needing them explained.")
                    }
                }
            } else {
                Section {
                    ForEach(environment.userProfile.people) { person in
                        NavigationLink(value: PeopleRoute.detail(person.id)) {
                            PersonRow(person: person)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("People")
        .navigationDestination(for: PeopleRoute.self) { route in
            switch route {
            case .detail(let id):
                PersonDetailView(personID: id)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingPerson = true
                } label: {
                    Label("Add person", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingPerson) {
            addPersonSheet
        }
        .errorAlert(title: "Couldn't save", message: $errorMessage)
        .task {
            await environment.refreshUserProfile()
        }
    }

    private var addPersonSheet: some View {
        NavigationStack {
            Form {
                Section("Who is this?") {
                    TextField("Name", text: $newName)
                        .textInputAutocapitalization(.words)
                    TextField("Relationship (son, wife, manager…)", text: $newRelationship)
                }
            }
            .navigationTitle("Add someone")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismissSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { addPerson() }
                        .disabled(newName.isBlank)
                }
            }
        }
    }

    private func addPerson() {
        let name = newName
        let relationship = newRelationship.isBlank ? nil : newRelationship
        dismissSheet()
        Task {
            do {
                _ = try await environment.userProfileStore.createPerson(
                    name: name,
                    relationship: relationship,
                    sourceMemoryID: nil
                )
                await environment.refreshUserProfile()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let ids = offsets.map { environment.userProfile.people[$0].id }
        Task {
            do {
                try await environment.userProfileStore.deletePeople(ids: ids)
                await environment.refreshUserProfile()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func dismissSheet() {
        isAddingPerson = false
        newName = ""
        newRelationship = ""
    }
}

enum PeopleRoute: Hashable {
    case detail(UUID)
}

@MainActor

private struct PersonRow: View {
    let person: PersonProfileSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.displayName)
                    .font(.body)
                if let subtitle = person.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if person.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One person's record, editable.
@MainActor
struct PersonDetailView: View {
    let personID: UUID

    @Environment(AppEnvironment.self) private var environment

    @State private var person: PersonProfileSnapshot?
    @State private var nickname = ""
    @State private var relationship = ""
    @State private var education = ""
    @State private var work = ""
    @State private var notes = ""
    @State private var hasLoaded = false

    var body: some View {
        Form {
            if let person {
                Section("Details") {
                    LabeledTextField(title: "Goes by", placeholder: "Nickname", text: $nickname) {
                        commit { $0.nickname = .some(nickname) }
                    }
                    LabeledTextField(title: "Relationship", placeholder: "son, wife, manager…", text: $relationship) {
                        commit { $0.relationship = .some(relationship) }
                    }
                    LabeledTextField(title: "Studies", placeholder: "School and major", text: $education) {
                        commit { $0.education = .some(education) }
                    }
                    LabeledTextField(title: "Work", placeholder: "What they do", text: $work) {
                        commit { $0.work = .some(work) }
                    }
                }

                StringListSection(
                    title: "Things to know",
                    placeholder: "Add a fact",
                    symbolName: "info.circle",
                    values: person.importantFacts
                ) { updated in
                    await commitAsync { $0.importantFacts = updated }
                }

                StringListSection(
                    title: "Interests",
                    placeholder: "Add an interest",
                    symbolName: "sparkles",
                    values: person.interests
                ) { updated in
                    await commitAsync { $0.interests = updated }
                }

                StringListSection(
                    title: "Preferences",
                    placeholder: "Add a preference",
                    symbolName: "heart",
                    values: person.preferences
                ) { updated in
                    await commitAsync { $0.preferences = updated }
                }

                if !person.importantDates.isEmpty {
                    Section("Dates") {
                        ForEach(person.importantDates) { entry in
                            HStack {
                                Text(entry.title)
                                Spacer()
                                Text(entry.date.formatted(date: .abbreviated, time: .omitted))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    LabeledTextField(title: "Notes", placeholder: "Anything else", text: $notes) {
                        commit { $0.notes = .some(notes) }
                    }
                }
            } else {
                ContentUnavailableView(
                    "Not found",
                    systemImage: "person.slash",
                    description: Text("I no longer have a record for this person.")
                )
            }
        }
        .navigationTitle(person?.displayName ?? "Person")
        .task {
            guard !hasLoaded else { return }
            await reload()
            hasLoaded = true
        }
    }

    private func reload() async {
        person = try? await environment.userProfileStore.person(id: personID)
        guard let person else { return }
        nickname = person.nickname ?? ""
        relationship = person.relationship ?? ""
        education = person.education ?? ""
        work = person.work ?? ""
        notes = person.notes ?? ""
    }

    private func commit(_ configure: (inout PersonProfileMutation) -> Void) {
        Task { await commitAsync(configure) }
    }

    private func commitAsync(_ configure: (inout PersonProfileMutation) -> Void) async {
        var mutation = PersonProfileMutation()
        configure(&mutation)
        guard !mutation.isEmpty else { return }
        do {
            person = try await environment.userProfileStore.updatePerson(id: personID, with: mutation)
            await environment.refreshUserProfile()
        } catch {
            AuraLog.app.error("Failed to update person record.")
        }
    }
}

#Preview {
    NavigationStack {
        PeopleListView()
    }
    .environment(AppEnvironment.preview())
}
