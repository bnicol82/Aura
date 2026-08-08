import SwiftUI

/// Past conversations, and search across everything ever said (§45, §46).
///
/// ### Why this reads the store directly rather than through `@Query`
/// The rest of the app renders SwiftData with `@Query`, which is right when the view wants "all rows of a
/// type". This screen wants two different things — a page of recent conversations, or the results of a
/// full-text search — and which one depends on what the user typed. `ConversationStoring` already answers
/// both questions, so the view asks it rather than filtering a fetch of every message in the database.
///
/// ### Search is over messages, results are conversations
/// People remember *what was said*, not which conversation they said it in, so a search for "garage" has to
/// match message text. But opening a single message out of context is useless, so each hit is presented as
/// the conversation it belongs to, with the matching line as the subtitle.
@MainActor
struct ConversationHistoryView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var conversations: [ConversationSnapshot] = []
    @State private var searchHits: [ConversationSearchHit] = []
    @State private var searchText = ""
    @State private var includesArchived = false
    @State private var isLoading = true
    @State private var errorMessage: String?

    /// Renaming happens in an alert rather than inline: a list row that becomes editable on tap fights with
    /// tapping the row to open it.
    @State private var renamingID: UUID?
    @State private var renameText = ""

    private var isSearching: Bool { !searchText.isBlank }

    var body: some View {
        List {
            if isSearching {
                searchResults
            } else {
                conversationList
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("History")
        .searchable(text: $searchText, prompt: "Search everything you've said")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Archived conversations are hidden by default but never deleted, so "archive" stays a
                // reversible action rather than a euphemism for losing something.
                Toggle(isOn: $includesArchived) {
                    Label("Show archived", systemImage: includesArchived ? "archivebox.fill" : "archivebox")
                }
                .toggleStyle(.button)
            }
        }
        .task(id: includesArchived) { await loadConversations() }
        .task(id: searchText) { await runSearch() }
        .alert("Rename conversation", isPresented: renamingBinding) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") { commitRename() }
        }
        .errorAlert(title: "Couldn't do that", message: $errorMessage)
    }

    // MARK: - Lists

    @ViewBuilder
    private var conversationList: some View {
        if isLoading {
            // A row rather than a full-screen spinner: the list is usually cached and this flashes for a
            // fraction of a second, so replacing the whole screen would be more jarring than waiting.
            HStack {
                ProgressView()
                Text("Loading…").foregroundStyle(.secondary)
            }
        } else if conversations.isEmpty {
            ContentUnavailableView(
                "No conversations yet",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Everything you and \(environment.assistantName) talk about will be listed here.")
            )
        } else {
            ForEach(conversations) { conversation in
                Button {
                    open(conversation.id)
                } label: {
                    ConversationRow(conversation: conversation)
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(conversation.id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }

                    Button {
                        setArchived(!conversation.isArchived, id: conversation.id)
                    } label: {
                        Label(
                            conversation.isArchived ? "Unarchive" : "Archive",
                            systemImage: conversation.isArchived ? "tray.and.arrow.up" : "archivebox"
                        )
                    }
                    .tint(.gray)
                }
                .swipeActions(edge: .leading) {
                    Button {
                        setPinned(!conversation.isPinned, id: conversation.id)
                    } label: {
                        Label(
                            conversation.isPinned ? "Unpin" : "Pin",
                            systemImage: conversation.isPinned ? "pin.slash" : "pin"
                        )
                    }
                    .tint(.orange)

                    Button {
                        renamingID = conversation.id
                        renameText = conversation.title
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if searchHits.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            Section {
                ForEach(searchHits) { hit in
                    Button {
                        open(hit.conversationID)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hit.conversationTitle)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(hit.excerpt)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(hit.message.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Searching only what's on this iPhone. Nothing is sent anywhere to run a search.")
            }
        }
    }

    // MARK: - Actions

    private func open(_ id: UUID) {
        environment.conversation.open(conversationID: id)
        dismiss()
    }

    private func loadConversations() async {
        do {
            conversations = try await environment.conversationStore.recentConversations(
                limit: 200,
                includeArchived: includesArchived
            )
        } catch {
            errorMessage = error.asAuraError.errorDescription
        }
        isLoading = false
    }

    private func runSearch() async {
        guard isSearching else {
            searchHits = []
            return
        }
        // Debounced by hand: `task(id:)` restarts on every keystroke, and a cancelled sleep means the query
        // never runs for text the user has already typed past.
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            return
        }
        do {
            searchHits = try await environment.conversationStore.searchMessages(
                matching: searchText,
                limit: 60
            )
        } catch {
            errorMessage = error.asAuraError.errorDescription
        }
    }

    private func setArchived(_ archived: Bool, id: UUID) {
        Task {
            do {
                try await environment.conversationStore.setConversationArchived(archived, id: id)
                await loadConversations()
            } catch {
                errorMessage = error.asAuraError.errorDescription
            }
        }
    }

    private func setPinned(_ pinned: Bool, id: UUID) {
        Task {
            do {
                try await environment.conversationStore.setConversationPinned(pinned, id: id)
                await loadConversations()
            } catch {
                errorMessage = error.asAuraError.errorDescription
            }
        }
    }

    private func delete(_ id: UUID) {
        Task {
            do {
                try await environment.conversationStore.deleteConversations(ids: [id])
                // If the open conversation was the one deleted, the composer must not keep writing into a
                // row that no longer exists.
                if environment.conversation.conversationID == id {
                    environment.conversation.startNewConversation()
                }
                await loadConversations()
            } catch {
                errorMessage = error.asAuraError.errorDescription
            }
        }
    }

    private var renamingBinding: Binding<Bool> {
        Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )
    }

    private func commitRename() {
        guard let id = renamingID else { return }
        let title = renameText.normalizedWhitespace
        renamingID = nil
        guard !title.isEmpty else { return }

        Task {
            do {
                try await environment.conversationStore.renameConversation(id: id, title: title)
                await loadConversations()
            } catch {
                errorMessage = error.asAuraError.errorDescription
            }
        }
    }
}

/// One conversation in the list.
@MainActor
private struct ConversationRow: View {
    let conversation: ConversationSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if conversation.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(conversation.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let preview = conversation.lastMessagePreview, !preview.isBlank {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Text(conversation.updatedAt.formatted(.relative(presentation: .named)))
                    Text("·")
                    // Message count rather than turn count, because that is what the store actually knows
                    // and inventing a turn count would be a number nobody could reconcile.
                    Text("\(conversation.messageCount) message\(conversation.messageCount == 1 ? "" : "s")")
                    if conversation.isArchived {
                        Text("·")
                        Text("Archived")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)
        }
        .padding(.vertical, 2)
        .contentShape(.rect)
    }
}
