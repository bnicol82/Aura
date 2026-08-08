import SwiftUI

/// The four places in AURA (§42).
enum AppTab: String, CaseIterable, Identifiable, Hashable {
    case assistant
    case memory
    case activity
    case settings

    var id: String { rawValue }

    /// The Memory tab is titled after the user's own assistant, which is why this takes a name.
    func title(assistantName: String) -> String {
        switch self {
        case .assistant: return assistantName
        case .memory: return "Memory"
        case .activity: return "Activity"
        case .settings: return "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .assistant: return "waveform.circle"
        case .memory: return "brain"
        case .activity: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

@MainActor

struct MainTabView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selectedTab: AppTab = .assistant

    var body: some View {
        TabView(selection: $selectedTab) {
            // The explicit `label:` form is used throughout rather than the title shorthand, because
            // the first tab's title is the user's chosen assistant name — a runtime `String`, not a
            // localizable literal.
            Tab(value: AppTab.assistant) {
                AssistantHomeView()
            } label: {
                Label(environment.assistantName, systemImage: AppTab.assistant.symbolName)
            }

            Tab(value: AppTab.memory) {
                MemoryHomeView()
            } label: {
                Label(AppTab.memory.title(assistantName: environment.assistantName), systemImage: AppTab.memory.symbolName)
            }

            Tab(value: AppTab.activity) {
                ActivityHomeView()
            } label: {
                Label(AppTab.activity.title(assistantName: environment.assistantName), systemImage: AppTab.activity.symbolName)
            }

            Tab(value: AppTab.settings) {
                SettingsHomeView()
            } label: {
                Label(AppTab.settings.title(assistantName: environment.assistantName), systemImage: AppTab.settings.symbolName)
            }
        }
    }
}

#Preview {
    MainTabView()
        .environment(AppEnvironment.preview())
}
