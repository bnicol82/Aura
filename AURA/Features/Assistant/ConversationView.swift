import SwiftData
import SwiftUI

/// The conversation screen (§43).
///
/// The transcript renders from SwiftData, not from view state. The orchestrator writes a turn, `@Query`
/// notices, and the screen updates — which means the transcript is always exactly what was persisted.
/// There is no second copy of the conversation in the UI that could drift from the store.
@MainActor
struct ConversationView: View {
    @Environment(AppEnvironment.self) private var environment

    @FocusState private var isComposerFocused: Bool
    @State private var isShowingHistory = false

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(environment.assistantName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    controller.startNewConversation()
                } label: {
                    Label("New conversation", systemImage: "plus.message")
                }
                .disabled(controller.isBusy || controller.conversationID == nil)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isShowingHistory = true
                } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .disabled(!FeatureFlags.conversationHistory.isLive)
            }
        }
        // A sheet rather than a push: history is a place you dip into and come back from, and it has to be
        // reachable from the conversation it will send you back to.
        .sheet(isPresented: $isShowingHistory) {
            NavigationStack { ConversationHistoryView() }
        }
        .task { await controller.prepare() }
        .errorAlert(title: "That didn't work", message: Binding(
            get: { controller.errorMessage },
            set: { controller.errorMessage = $0 }
        ))
        // Separate from the turn error: a microphone that cannot open is a different problem from an answer
        // that failed, and saying so beats a button that appears to do nothing.
        .errorAlert(title: "I can't listen", message: Binding(
            get: { controller.voiceUnavailableMessage },
            set: { controller.voiceUnavailableMessage = $0 }
        ))
    }

    private var controller: ConversationController { environment.conversation }

    // MARK: - Transcript

    @ViewBuilder
    private var transcript: some View {
        if let conversationID = controller.conversationID {
            TranscriptView(
                conversationID: conversationID,
                assistantName: environment.assistantName,
                streamingText: controller.streamingText
            )
        } else {
            ScrollView {
                emptyState.padding(.top, 60)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            AssistantOrbView(state: controller.state)
                .frame(width: 120, height: 120)
            Text("What can I help with?")
                .font(.headline)
            Text("Ask me something, or tell me something worth remembering.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 8) {
            if let statusText = controller.statusText {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        Task { await controller.cancel() }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            if controller.isListening {
                // The live transcript sits above the composer rather than inside it: it is not a draft the
                // user can edit, and putting it in the field would invite them to try.
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .foregroundStyle(.red)
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(controller.state.statusText)
                        .font(.callout)
                        .foregroundStyle(controller.state.liveTranscript?.isEmpty == false ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message \(environment.assistantName)",
                    text: Binding(
                        get: { controller.draft },
                        set: { controller.draft = $0 }
                    ),
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .focused($isComposerFocused)
                .disabled(controller.isBusy)
                .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!controller.canSend)
                .accessibilityLabel("Send")

                Button {
                    Task { await controller.toggleListening() }
                } label: {
                    Image(systemName: controller.isListening ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 30))
                        // Red while live, because "is the microphone open" is the one thing about this
                        // screen a user must never have to guess.
                        .foregroundStyle(controller.isListening ? Color.red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: controller.isListening)
                }
                .disabled(!controller.canListen && !controller.isListening)
                .accessibilityLabel(controller.isListening ? "Stop listening" : "Talk")
                .accessibilityHint(FeatureFlags.voiceInput.userFacingNote ?? "")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private func send() {
        Task { await controller.send() }
    }
}

/// The message list for one conversation.
///
/// Separate from `ConversationView` so its `@Query` can be built from a specific conversation id.
/// SwiftUI re-initialises this view when the id changes, which rebuilds the query — the supported way to
/// scope a query to a value that is not known at compile time.
@MainActor
private struct TranscriptView: View {
    private let conversationID: UUID
    private let assistantName: String
    private let streamingText: String?

    @Query private var messages: [Message]

    init(conversationID: UUID, assistantName: String, streamingText: String?) {
        self.conversationID = conversationID
        self.assistantName = assistantName
        self.streamingText = streamingText
        _messages = Query(
            filter: #Predicate<Message> { $0.conversation?.id == conversationID },
            sort: [
                SortDescriptor(\Message.createdAt, order: .forward),
                SortDescriptor(\Message.sequence, order: .forward)
            ]
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleMessages) { message in
                        MessageRow(message: message.snapshot, assistantName: assistantName)
                            // Row ids are strings throughout, including the streaming placeholder, so
                            // `scrollTo` never has to match across two id types.
                            .id(message.id.uuidString)
                    }

                    if let streamingText, !streamingText.isEmpty {
                        MessageRow(
                            message: MessageSnapshot(role: .assistant, content: streamingText),
                            assistantName: assistantName
                        )
                        .id(Self.streamingRowID)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) { _, _ in
                scrollToEnd(proxy)
            }
            .onChange(of: streamingText) { _, _ in
                scrollToEnd(proxy)
            }
        }
    }

    /// System and tool rows are internal bookkeeping, not part of the conversation.
    private var visibleMessages: [Message] {
        messages.filter { $0.role == .user || $0.role == .assistant }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        let target: String? = (streamingText?.isEmpty == false)
            ? Self.streamingRowID
            : visibleMessages.last?.id.uuidString
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(target, anchor: .bottom)
        }
    }

    private static let streamingRowID = "aura.streaming.row"
}

/// One turn in the transcript.
@MainActor
struct MessageRow: View {
    let message: MessageSnapshot
    let assistantName: String

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 6) {
            if !message.toolActivity.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(message.toolActivity) { note in
                        ToolActivityRow(note: note)
                    }
                }
            }

            Text(message.content)
                .font(.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .foregroundStyle(message.isFailure ? Color.secondary : Color.primary)
                .frame(maxWidth: 320, alignment: message.role == .user ? .trailing : .leading)

            if message.isFailure {
                Label("I couldn't do that", systemImage: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.role == .user ? "You said" : "\(assistantName) said")
        .accessibilityValue(message.content)
    }

    private var bubbleBackground: Color {
        switch message.role {
        case .user:
            return Color.accentColor.opacity(0.18)
        case .assistant:
            return Color(.secondarySystemGroupedBackground)
        case .system, .tool:
            return Color(.tertiarySystemGroupedBackground)
        }
    }
}

/// A tool-activity row: "Checking your calendar".
///
/// This is the whole of what the transcript reveals about how an answer was produced. Actions, never
/// reasoning (§36, §43).
@MainActor
struct ToolActivityRow: View {
    let note: ToolActivityNote

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: note.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(note.succeeded ? Color.secondary : Color.orange)
            Text(note.outcome ?? note.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    // `@Query` needs the same container the environment holds, so both come from one instance.
    let environment = AppEnvironment.preview()
    NavigationStack {
        ConversationView()
    }
    .environment(environment)
    .modelContainer(environment.persistence.container)
}
