import SwiftUI

/// The facts AURA holds in one category, viewable and editable (§25).
///
/// Every capability §25 asks for is here — view, edit, correct, pin, archive, delete, add by hand.
/// Correcting a value goes through `upsertFact`, which supersedes rather than overwrites, so the
/// previous answer is archived rather than erased (§23).
@MainActor
struct ProfileFactListView: View {
    let category: MemoryCategory

    @Environment(AppEnvironment.self) private var environment

    @State private var facts: [ProfileFactSnapshot] = []
    @State private var isAddingFact = false
    @State private var newKey = ""
    @State private var newValue = ""
    @State private var editingFact: ProfileFactSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if facts.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Nothing here yet", systemImage: category.symbolName)
                    } description: {
                        Text("Add something you'd want me to remember about \(category.displayName.lowercased()).")
                    }
                }
            } else {
                Section {
                    ForEach(facts) { fact in
                        FactRow(fact: fact)
                            .contentShape(Rectangle())
                            .onTapGesture { editingFact = fact }
                            .swipeActions(edge: .leading) {
                                Button {
                                    setPinned(!fact.isPinned, id: fact.id)
                                } label: {
                                    Label(
                                        fact.isPinned ? "Unpin" : "Pin",
                                        systemImage: fact.isPinned ? "pin.slash" : "pin"
                                    )
                                }
                                .tint(.orange)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(id: fact.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    archive(id: fact.id)
                                } label: {
                                    Label("Archive", systemImage: "archivebox")
                                }
                                .tint(.gray)
                            }
                    }
                } footer: {
                    Text("Swipe a row to pin, archive or delete it. Tap to correct it.")
                }
            }
        }
        .navigationTitle(category.displayName)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAddingFact = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isAddingFact) {
            factEditor(
                title: "Add a fact",
                keyText: $newKey,
                valueText: $newValue,
                confirmLabel: "Save"
            ) {
                save(key: newKey, value: newValue)
            }
        }
        .sheet(item: $editingFact) { fact in
            CorrectFactSheet(fact: fact) { updatedValue in
                save(key: fact.key, value: updatedValue)
            }
        }
        .errorAlert(title: "Couldn't save", message: $errorMessage)
        .task { await reload() }
    }

    // MARK: - Editor

    private func factEditor(
        title: String,
        keyText: Binding<String>,
        valueText: Binding<String>,
        confirmLabel: String,
        onConfirm: @escaping () -> Void
    ) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What is it? (e.g. Favourite driver)", text: keyText)
                    TextField("What's the answer?", text: valueText)
                } footer: {
                    Text("Anything you add here I treat as certain, because you told me directly.")
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismissAddSheet() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmLabel) { onConfirm() }
                        .disabled(keyText.wrappedValue.isBlank || valueText.wrappedValue.isBlank)
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        do {
            facts = try await environment.userProfileStore.facts(in: [category])
        } catch {
            errorMessage = error.auraDescription
        }
    }

    private func save(key: String, value: String) {
        dismissAddSheet()
        editingFact = nil
        Task {
            do {
                _ = try await environment.userProfileStore.upsertFact(
                    key: key,
                    value: value,
                    category: category,
                    // Entered by hand, so it is a stated fact, not an inference (§22).
                    confidence: AuraDefaults.Confidence.explicit,
                    sourceMemoryID: nil
                )
                await reload()
                await environment.refreshUserProfile()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func setPinned(_ pinned: Bool, id: UUID) {
        Task {
            do {
                try await environment.userProfileStore.setFactPinned(pinned, id: id)
                await reload()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func archive(id: UUID) {
        Task {
            do {
                try await environment.userProfileStore.setFactArchived(true, id: id)
                await reload()
                await environment.refreshUserProfile()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func delete(id: UUID) {
        Task {
            do {
                try await environment.userProfileStore.deleteFacts(ids: [id])
                await reload()
                await environment.refreshUserProfile()
            } catch {
                errorMessage = error.auraDescription
            }
        }
    }

    private func dismissAddSheet() {
        isAddingFact = false
        newKey = ""
        newValue = ""
    }
}

@MainActor
private struct FactRow: View {
    let fact: ProfileFactSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.key)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(fact.value)
                    .font(.body)
                if fact.confidence < AuraDefaults.Confidence.inferred {
                    // Low-confidence facts are labelled rather than shown as settled, so the screen
                    // matches what AURA will actually say about them (§22).
                    Label("You weren't sure about this", systemImage: "questionmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if fact.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Correcting a fact. Shows the current value so the user can see what they are changing.
@MainActor
private struct CorrectFactSheet: View {
    let fact: ProfileFactSnapshot
    let onSave: (String) -> Void

    @State private var value: String
    @Environment(\.dismiss) private var dismiss

    init(fact: ProfileFactSnapshot, onSave: @escaping (String) -> Void) {
        self.fact = fact
        self.onSave = onSave
        _value = State(initialValue: fact.value)
    }

    var body: some View {
        NavigationStack {
            Form {
                // The explicit `header:` form is required, not stylistic: SwiftUI has no
                // `Section(_ title:, content:, footer:)` initializer — a title string and a footer
                // closure cannot be combined. `Text(_:)` with a `StringProtocol` argument also keeps
                // `fact.key` out of localization lookup, which is right for user-entered text.
                Section {
                    TextField("Answer", text: $value)
                } header: {
                    Text(fact.key)
                } footer: {
                    Text("I'll keep the old answer archived rather than deleting it, so you can see what changed.")
                }
            }
            .navigationTitle("Correct this")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(value) }
                        .disabled(value.isBlank || value == fact.value)
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        ProfileFactListView(category: .personalPreference)
    }
    .environment(AppEnvironment.preview())
}
