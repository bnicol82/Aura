import Foundation
import OSLog

/// Central `OSLog` categories for AURA.
///
/// Privacy rule for this app: **never interpolate user content, memory content, transcripts or
/// model prompts into a log line.** `Logger` treats string interpolations as `.private` by default,
/// which redacts them in release builds, but redaction is not a licence to log personal text — a
/// device attached to a debugger shows private values in the clear. Log *shapes* instead: counts,
/// identifiers, durations, category names, error kinds.
///
/// Anything that is safe to show a stranger may be marked `privacy: .public` explicitly.
enum AuraLog {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.aura.assistant"

    /// App lifecycle, navigation, dependency wiring.
    static let app = Logger(subsystem: subsystem, category: "app")
    /// SwiftData container setup, migrations, store health.
    static let storage = Logger(subsystem: subsystem, category: "storage")
    /// CloudKit sync activity and conflicts.
    static let sync = Logger(subsystem: subsystem, category: "sync")
    /// Language model routing, availability, provider selection.
    static let model = Logger(subsystem: subsystem, category: "model")
    /// Orchestrator turn lifecycle.
    static let orchestrator = Logger(subsystem: subsystem, category: "orchestrator")
    /// Memory extraction, scoring, retrieval.
    static let memory = Logger(subsystem: subsystem, category: "memory")
    /// Tool resolution, confirmation, execution.
    static let tools = Logger(subsystem: subsystem, category: "tools")
    /// Speech recognition and synthesis.
    static let voice = Logger(subsystem: subsystem, category: "voice")
    /// Permission requests and authorization state.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    /// Keychain access.
    static let security = Logger(subsystem: subsystem, category: "security")
}
