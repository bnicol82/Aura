import Foundation

/// The set of tools AURA can offer a model on a given turn (§33).
///
/// Registration happens once at launch. Which tools a *particular* request sees is a narrower
/// question, answered by `availableTools(for:)`: a tool whose permission was denied, or that needs
/// the network while the device is offline, is withheld rather than offered and then failed. Offering
/// a tool that cannot run invites the model to promise something AURA cannot deliver (§78).
actor ToolRegistry {

    /// What a request is allowed to reach for.
    struct AvailabilityCriteria: Sendable, Equatable {
        /// Permissions currently usable. A tool needing anything outside this set is withheld.
        var grantedPermissions: Set<AuraPermission>
        /// The subset of `grantedPermissions` that is only *partially* granted — write-only calendar
        /// access, a limited address book. Usable, but not enough for a tool that sets
        /// `requiresFullPermissionAccess`.
        var partiallyGrantedPermissions: Set<AuraPermission>
        var isOnline: Bool
        /// Highest tier this turn may use. Lets a widget or a Shortcut run read-only tools while
        /// refusing consequential ones, since there is nobody present to confirm.
        var maximumRiskLevel: ToolRiskLevel
        /// Explicit allow list. `nil` means "everything else that qualifies".
        var restrictedToIDs: Set<String>?

        init(
            grantedPermissions: Set<AuraPermission> = [],
            partiallyGrantedPermissions: Set<AuraPermission> = [],
            isOnline: Bool = true,
            maximumRiskLevel: ToolRiskLevel = .consequential,
            restrictedToIDs: Set<String>? = nil
        ) {
            self.grantedPermissions = grantedPermissions
            self.partiallyGrantedPermissions = partiallyGrantedPermissions
            self.isOnline = isOnline
            self.maximumRiskLevel = maximumRiskLevel
            self.restrictedToIDs = restrictedToIDs
        }

        /// Everything, for tests and for the fully-permissioned foreground case.
        static let unrestricted = AvailabilityCriteria(
            grantedPermissions: Set(AuraPermission.allCases),
            isOnline: true,
            maximumRiskLevel: .consequential
        )

        /// Read-only, offline-safe: the right posture for an unattended entry point.
        static let unattended = AvailabilityCriteria(
            grantedPermissions: [],
            isOnline: false,
            maximumRiskLevel: .readOnly
        )
    }

    private var toolsByID: [String: any AssistantTool] = [:]
    /// Model-facing name → id. Providers call tools by name; audit records key on id.
    private var idsByName: [String: String] = [:]

    init(tools: [any AssistantTool] = []) {
        for tool in tools {
            toolsByID[tool.id] = tool
            idsByName[tool.name] = tool.id
        }
    }

    /// Registers a tool, replacing any previous tool with the same id.
    func register(_ tool: any AssistantTool) {
        if let existing = toolsByID[tool.id] {
            idsByName.removeValue(forKey: existing.name)
            AuraLog.tools.notice("Replacing registered tool \(tool.id, privacy: .public)")
        }
        toolsByID[tool.id] = tool
        idsByName[tool.name] = tool.id
    }

    func register(_ tools: [any AssistantTool]) {
        for tool in tools { register(tool) }
    }

    func unregister(id: String) {
        guard let tool = toolsByID.removeValue(forKey: id) else { return }
        idsByName.removeValue(forKey: tool.name)
    }

    var allTools: [any AssistantTool] {
        toolsByID.values.sorted { $0.id < $1.id }
    }

    func tool(id: String) -> (any AssistantTool)? {
        toolsByID[id]
    }

    /// Looks up by the name the model used.
    func tool(named name: String) -> (any AssistantTool)? {
        guard let id = idsByName[name] else { return nil }
        return toolsByID[id]
    }

    /// The tools that qualify under `criteria`, in a stable order.
    func availableTools(for criteria: AvailabilityCriteria) -> [any AssistantTool] {
        allTools.filter { tool in
            if let allowed = criteria.restrictedToIDs, !allowed.contains(tool.id) { return false }
            if tool.riskLevel > criteria.maximumRiskLevel { return false }
            if !criteria.isOnline && !tool.worksOffline { return false }
            guard tool.requiredPermissions.isSubset(of: criteria.grantedPermissions) else { return false }
            if tool.requiresFullPermissionAccess {
                return tool.requiredPermissions.isDisjoint(with: criteria.partiallyGrantedPermissions)
            }
            return true
        }
    }

    /// The same set, rendered for a `ModelRequest`.
    func availableDefinitions(for criteria: AvailabilityCriteria) -> [ToolDefinition] {
        availableTools(for: criteria).map(\.definition)
    }

    /// Tools excluded by `criteria`, paired with why.
    ///
    /// Used by the Privacy and Permissions screens to explain what is switched off and what would
    /// turn it back on, rather than leaving capabilities silently missing (§52).
    func unavailableTools(
        for criteria: AvailabilityCriteria
    ) -> [(tool: any AssistantTool, reason: String)] {
        allTools.compactMap { tool in
            if let allowed = criteria.restrictedToIDs, !allowed.contains(tool.id) {
                return (tool, "Not offered for this kind of request.")
            }
            if tool.riskLevel > criteria.maximumRiskLevel {
                return (tool, "Needs you to be here to confirm it.")
            }
            if !criteria.isOnline && !tool.worksOffline {
                return (tool, "Needs an internet connection.")
            }
            let missing = tool.requiredPermissions.subtracting(criteria.grantedPermissions)
            if !missing.isEmpty {
                let names = missing.map(\.displayName).sorted().joined(separator: ", ")
                return (tool, "Needs \(names) access.")
            }
            if tool.requiresFullPermissionAccess {
                let partial = tool.requiredPermissions.intersection(criteria.partiallyGrantedPermissions)
                if !partial.isEmpty {
                    let names = partial.map(\.displayName).sorted().joined(separator: ", ")
                    return (tool, "Needs full \(names) access, not just permission to add.")
                }
            }
            return nil
        }
    }
}
