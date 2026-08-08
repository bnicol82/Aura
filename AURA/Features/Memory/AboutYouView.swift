import SwiftUI

/// The editable user profile (§25, §26).
///
/// Teaching AURA by hand has to work independently of the assistant learning on its own. Two reasons:
/// automatic extraction will always miss things, and a person who has just read "here's what I know
/// about you" needs to be able to fix it on the spot rather than by arguing with a chatbot.
@MainActor
struct AboutYouView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Local edit buffers. Text fields commit on blur or on Done rather than on every keystroke — a
    /// store round trip per character would bump `updatedAt` constantly and, once CloudKit is on,
    /// generate a push per letter typed.
    @State private var preferredName = ""
    @State private var pronouns = ""
    @State private var workContext = ""
    @State private var educationContext = ""
    @State private var locationContext = ""
    @State private var hasLoaded = false

    var body: some View {
        Form {
            Section {
                LabeledTextField(
                    title: "What should I call you?",
                    placeholder: "Your name",
                    text: $preferredName
                ) { commitPreferredName() }

                LabeledTextField(
                    title: "Pronouns",
                    placeholder: "Optional",
                    text: $pronouns
                ) { commitPronouns() }
            } header: {
                Text("You")
            } footer: {
                Text("I'll only use a name if you give me one — I won't guess.")
            }

            Section("Context") {
                LabeledTextField(
                    title: "Work",
                    placeholder: "What you do",
                    text: $workContext
                ) { commitWork() }

                LabeledTextField(
                    title: "Education",
                    placeholder: "Where you studied",
                    text: $educationContext
                ) { commitEducation() }

                LabeledTextField(
                    title: "Where you are",
                    placeholder: "City or region",
                    text: $locationContext
                ) { commitLocation() }
            }

            StringListSection(
                title: "Interests",
                placeholder: "Add an interest",
                symbolName: "sparkles",
                values: environment.userProfile.interests
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.interests = updated
                await environment.update(mutation)
            }

            StringListSection(
                title: "Hobbies",
                placeholder: "Add a hobby",
                symbolName: "figure.walk",
                values: environment.userProfile.hobbies
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.hobbies = updated
                await environment.update(mutation)
            }

            StringListSection(
                title: "Goals",
                placeholder: "Add a goal",
                symbolName: "target",
                values: environment.userProfile.longTermGoals
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.longTermGoals = updated
                await environment.update(mutation)
            }

            StringListSection(
                title: "Routines",
                placeholder: "Add a routine",
                symbolName: "repeat",
                values: environment.userProfile.routines
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.routines = updated
                await environment.update(mutation)
            }

            StringListSection(
                title: "Places that matter",
                placeholder: "Add a place",
                symbolName: "mappin.and.ellipse",
                values: environment.userProfile.importantPlaces
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.importantPlaces = updated
                await environment.update(mutation)
            }

            StringListSection(
                title: "Always keep in mind",
                placeholder: "Add an instruction",
                symbolName: "exclamationmark.bubble",
                values: environment.userProfile.assistantInstructions,
                footer: "These take priority over my usual style."
            ) { updated in
                var mutation = UserProfileMutation()
                mutation.assistantInstructions = updated
                await environment.update(mutation)
            }
        }
        .navigationTitle("About you")
        .task {
            guard !hasLoaded else { return }
            await environment.refreshUserProfile()
            loadBuffers()
            hasLoaded = true
        }
    }

    // MARK: - Buffers

    private func loadBuffers() {
        let profile = environment.userProfile
        preferredName = profile.preferredName ?? ""
        pronouns = profile.pronouns ?? ""
        workContext = profile.workContext ?? ""
        educationContext = profile.educationContext ?? ""
        locationContext = profile.locationContext ?? ""
    }

    private func commitPreferredName() {
        commit { mutation in mutation.preferredName = .some(preferredName) }
    }

    private func commitPronouns() {
        commit { mutation in mutation.pronouns = .some(pronouns) }
    }

    private func commitWork() {
        commit { mutation in mutation.workContext = .some(workContext) }
    }

    private func commitEducation() {
        commit { mutation in mutation.educationContext = .some(educationContext) }
    }

    private func commitLocation() {
        commit { mutation in mutation.locationContext = .some(locationContext) }
    }

    /// `.some("")` is meaningful here: the store's `apply` treats an empty string as "clear this
    /// field", which is how a user removes something they previously entered.
    private func commit(_ configure: (inout UserProfileMutation) -> Void) {
        var mutation = UserProfileMutation()
        configure(&mutation)
        Task { await environment.update(mutation) }
    }
}

/// A text field that reports when editing finishes, so writes happen on commit rather than per
/// keystroke.
@MainActor
struct LabeledTextField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let onCommit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(onCommit)
        }
        .onChange(of: isFocused) { wasFocused, nowFocused in
            if wasFocused && !nowFocused { onCommit() }
        }
    }
}

/// A `Form` section that edits a list of short strings.
///
/// The same shape serves interests, hobbies, goals, routines, places and standing instructions, which
/// is the payoff for modelling those as `[String]` rather than as six bespoke screens.
@MainActor
struct StringListSection: View {
    let title: String
    let placeholder: String
    let symbolName: String
    let values: [String]
    var footer: String?
    let onChange: @MainActor ([String]) async -> Void

    @State private var newValue = ""

    var body: some View {
        Section {
            ForEach(values, id: \.self) { value in
                Label(value, systemImage: symbolName)
            }
            .onDelete { offsets in
                var updated = values
                updated.remove(atOffsets: offsets)
                Task { await onChange(updated) }
            }

            HStack {
                TextField(placeholder, text: $newValue)
                    .submitLabel(.done)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newValue.isBlank)
            }
        } header: {
            Text(title)
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private func add() {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let updated = values + [trimmed]
        newValue = ""
        Task { await onChange(updated) }
    }
}

#Preview {
    NavigationStack {
        AboutYouView()
    }
    .environment(AppEnvironment.preview())
}
