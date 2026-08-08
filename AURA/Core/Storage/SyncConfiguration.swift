import Foundation
import SwiftData

/// Where AURA's durable data lives (§8).
///
/// AURA is local-first, always. The SQLite store on device is the working copy and everything keeps
/// working with no network and no iCloud account. CloudKit, when enabled, mirrors that store through
/// the user's **private** database so the same assistant shows up on their other devices.
///
/// iCloud is storage and sync only. No model ever runs there.
enum SyncConfiguration: Sendable, Equatable {
    /// Device-only. No iCloud container needed, no entitlements needed.
    case localOnly

    /// Mirror to the named CloudKit container's private database.
    ///
    /// Requires the iCloud/CloudKit entitlement and a container that exists in the signing team's
    /// account — see `Configuration/AURA.entitlements.template`.
    case cloudKit(containerIdentifier: String)

    /// Phase 1 default.
    ///
    /// Deliberately `.localOnly`: pointing at a CloudKit container that does not exist in the
    /// developer's account makes the app fail to provision, so a checked-out repository would not
    /// build. CloudKit is Phase 9; flipping this constant and wiring the entitlements is the switch.
    static let `default`: SyncConfiguration = .localOnly

    /// The container AURA uses once sync is turned on. Change this alongside the bundle identifier.
    static let defaultContainerIdentifier = "iCloud.com.aura.assistant"

    var isCloudEnabled: Bool {
        if case .cloudKit = self { return true }
        return false
    }

    var containerIdentifier: String? {
        if case .cloudKit(let identifier) = self { return identifier }
        return nil
    }

    /// Translates to SwiftData's mirroring option.
    var cloudKitDatabase: ModelConfiguration.CloudKitDatabase {
        switch self {
        case .localOnly:
            return .none
        case .cloudKit(let identifier):
            return .private(identifier)
        }
    }

    var statusLabel: String {
        switch self {
        case .localOnly: return "This iPhone only"
        case .cloudKit: return "Syncing with iCloud"
        }
    }
}
