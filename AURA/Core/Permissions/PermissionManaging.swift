import Foundation

/// Requests and reports system authorizations (§52).
///
/// Permissions are asked for at the moment a feature needs one, never in a batch during onboarding.
/// A person who has just asked "what's on my schedule tomorrow?" understands why the calendar prompt
/// appeared; the same prompt on screen three of setup is noise, and noise gets denied.
protocol PermissionManaging: Sendable {
    /// Current state without prompting. Safe to call for rendering.
    func status(for permission: AuraPermission) async -> PermissionStatus

    /// Requests the permission, showing the system prompt if it has not been shown before.
    ///
    /// Already-denied permissions return `.denied` without prompting — iOS shows nothing the second
    /// time, so re-asking would appear to hang. The caller sends the user to Settings instead.
    func request(_ permission: AuraPermission) async -> PermissionStatus

    /// Every permission's state, for the Privacy dashboard (§49).
    func allStatuses() async -> [AuraPermission: PermissionStatus]

    /// The set currently usable, which is what `ToolRegistry` filters against.
    func grantedPermissions() async -> Set<AuraPermission>
}

extension PermissionManaging {
    /// Ensures a permission is usable, throwing a specific error if not.
    ///
    /// The throw carries the permission, so the message names what is missing and how to grant it
    /// rather than failing vaguely (§52, §69).
    func requireUsable(_ permission: AuraPermission) async throws {
        let current = await status(for: permission)
        if current.isUsable { return }

        guard current == .notDetermined else {
            throw AuraError.permissionDenied(permission)
        }

        let updated = await request(permission)
        guard updated.isUsable else {
            throw AuraError.permissionDenied(permission)
        }
    }
}

/// A permission manager for tests and previews, with no system prompts.
actor StubPermissionManager: PermissionManaging {
    private var statuses: [AuraPermission: PermissionStatus]
    /// What `request(_:)` turns a `.notDetermined` permission into.
    private let requestOutcome: PermissionStatus

    init(
        statuses: [AuraPermission: PermissionStatus] = [:],
        requestOutcome: PermissionStatus = .authorized
    ) {
        self.statuses = statuses
        self.requestOutcome = requestOutcome
    }

    /// Everything granted.
    static func allowingEverything() -> StubPermissionManager {
        StubPermissionManager(
            statuses: Dictionary(uniqueKeysWithValues: AuraPermission.allCases.map { ($0, .authorized) })
        )
    }

    /// Everything denied — the degradation paths in §52.
    static func denyingEverything() -> StubPermissionManager {
        StubPermissionManager(
            statuses: Dictionary(uniqueKeysWithValues: AuraPermission.allCases.map { ($0, .denied) }),
            requestOutcome: .denied
        )
    }

    func status(for permission: AuraPermission) async -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    func request(_ permission: AuraPermission) async -> PermissionStatus {
        let current = statuses[permission] ?? .notDetermined
        guard current == .notDetermined else { return current }
        statuses[permission] = requestOutcome
        return requestOutcome
    }

    func allStatuses() async -> [AuraPermission: PermissionStatus] {
        var result: [AuraPermission: PermissionStatus] = [:]
        for permission in AuraPermission.allCases {
            result[permission] = statuses[permission] ?? .notDetermined
        }
        return result
    }

    func grantedPermissions() async -> Set<AuraPermission> {
        Set(statuses.filter { $0.value.isUsable }.keys)
    }
}
