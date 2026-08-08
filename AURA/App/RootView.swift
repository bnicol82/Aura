import SwiftUI

/// The app's top-level branch: onboarding, or the assistant.
@MainActor
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if !environment.isLoaded {
                LaunchPlaceholderView()
            } else if !environment.hasCompletedOnboarding {
                OnboardingFlowView()
            } else {
                MainTabView()
            }
        }
        .task {
            guard !environment.isLoaded else { return }
            await environment.load()
        }
        .animation(.easeInOut(duration: 0.25), value: environment.hasCompletedOnboarding)
        .overlay(alignment: .top) {
            if environment.isRunningWithoutPersistence {
                EphemeralStorageBanner()
            }
        }
    }
}

/// Shown for the moment between launch and the first profile load.
///
/// Not a spinner: the profile load is a local SQLite read and usually finishes within a frame, so a
/// spinner would flash. This is the same mark the home screen shows, which makes the transition read
/// as continuous rather than as two screens.
@MainActor
private struct LaunchPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            AssistantOrbView(state: .idle)
                .frame(width: 140, height: 140)
                .accessibilityHidden(true)
        }
    }
}

/// Warns that nothing is being saved this session.
///
/// A failed store is the one condition where saying nothing would be dishonest: the app looks
/// entirely functional while discarding everything the user tells it (§69, §78).
@MainActor
private struct EphemeralStorageBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Storage is unavailable. Nothing from this session will be saved.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Main") {
    RootView()
        .environment(AppEnvironment.preview())
}
