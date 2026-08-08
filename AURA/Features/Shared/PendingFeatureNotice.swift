import SwiftUI

/// The one way AURA tells the user a capability is not finished.
///
/// Centralised so the message is consistent and cannot drift into vague "coming soon" copy that
/// leaves someone wondering whether they did something wrong.
@MainActor
struct PendingFeatureNotice: View {
    let stage: FeatureStage
    var symbolName: String = "hammer.fill"

    var body: some View {
        if let note = stage.userFacingNote {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbolName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let badge = stage.badgeText {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }
}

/// A full-screen empty state for a screen whose content does not exist yet.
@MainActor
struct PendingFeatureScreen: View {
    let title: String
    let stage: FeatureStage
    var symbolName: String = "hammer"

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbolName)
        } description: {
            Text(stage.userFacingNote ?? "")
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        PendingFeatureNotice(stage: FeatureFlags.textConversation, symbolName: "bubble.left")
        PendingFeatureNotice(stage: FeatureFlags.voiceInput, symbolName: "mic")
        PendingFeatureScreen(title: "Activity", stage: FeatureFlags.activityLog)
    }
    .padding()
}
