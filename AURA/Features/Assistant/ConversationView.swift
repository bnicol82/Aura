import SwiftData
import SwiftUI

/// The conversation screen (§43).
///
/// The transcript, composer, tool-activity rows and provenance indicators are all real and read from
/// the store. What is not connected in Phase 1 is the thing behind the send button: there is no
/// model, no orchestrator, no reply. Rather than fake one, the composer is disabled and says so.
///
/// The alternative — accepting the message and showing a canned answer — would be exactly the
/// dishonesty §78 exists to prevent.
@MainActor
struct ConversationView: View {
    @Environment(AppEnvironment.self) private var environment

    /// Messages come straight from SwiftData. Once the orchestrator writes turns, this screen shows
    /// them with no further work.
    @Query(sort: \Message.createdAt, order: .forward)
    private var messages: [Message]

    @State private var draft = ""
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Divider()
            composer
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(environment.assistantName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty {
                        emptyState
                            .padding(.top, 60)
                    } else {
                        ForEach(messages) { message in
                            MessageRow(message: message.snapshot, assistantName: environment.assistantName)
                                .id(message.id)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: messages.count) { _, _ in
                guard let last = messages.last else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Nothing here yet.")
                .font(.headline)
            Text("This is where our conversations will live.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 10) {
            PendingFeatureNotice(
                stage: FeatureFlags.textConversation,
                symbolName: "bubble.left.and.text.bubble.right"
            )

            HStack(alignment: .bottom, spacing: 10) {
                TextField(
                    "Message \(environment.assistantName)",
                    text: $draft,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                .focused($isComposerFocused)
                .disabled(!FeatureFlags.textConversation.isLive)

                Button {
                    // No send path exists yet. Left empty rather than wired to a placebo.
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(true)
                .accessibilityLabel("Send")
                .accessibilityHint(FeatureFlags.textConversation.userFacingNote ?? "")

                Button {
                    // Voice input arrives in Phase 5.
                } label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(true)
                .accessibilityLabel("Talk")
                .accessibilityHint(FeatureFlags.voiceInput.userFacingNote ?? "")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
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
    // `@Query` needs the same container the environment holds, so both are injected from one
    // instance rather than two.
    let environment = AppEnvironment.preview()
    NavigationStack {
        ConversationView()
    }
    .environment(environment)
    .modelContainer(environment.persistence.container)
}
