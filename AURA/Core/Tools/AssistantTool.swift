import Foundation

/// Declares one parameter of a tool.
struct ToolParameter: Sendable, Equatable, Hashable {
    enum ValueType: String, Sendable, Equatable, Hashable {
        case string
        case integer
        case number
        case boolean
        case stringArray
        /// ISO 8601 text. Providers have no date type, so this is a string with a contract.
        case date
    }

    var name: String
    /// Written for the model, not the user: say what the value is for and what good input looks like.
    var description: String
    var type: ValueType
    var isRequired: Bool
    /// When non-empty, the only accepted values.
    var allowedValues: [String]

    init(
        name: String,
        description: String,
        type: ValueType = .string,
        isRequired: Bool = true,
        allowedValues: [String] = []
    ) {
        self.name = name
        self.description = description
        self.type = type
        self.isRequired = isRequired
        self.allowedValues = allowedValues
    }
}

/// A tool's parameter list, in one representation that every provider can be handed.
///
/// Providers need different shapes for the same information: cloud APIs want JSON Schema, Apple's
/// `FoundationModels.Tool` wants a `GenerationSchema`. Declaring parameters once in provider-neutral
/// terms means each provider adapter renders what it needs, and a tool author never writes a schema
/// twice.
struct ToolParameterSchema: Sendable, Equatable, Hashable {
    var parameters: [ToolParameter]

    init(_ parameters: [ToolParameter] = []) {
        self.parameters = parameters
    }

    static let none = ToolParameterSchema()

    var requiredNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }

    func parameter(named name: String) -> ToolParameter? {
        parameters.first { $0.name == name }
    }

    /// JSON Schema for cloud providers.
    func jsonSchema() -> JSONValue {
        var properties: [String: JSONValue] = [:]
        for parameter in parameters {
            var entry: [String: JSONValue] = [
                "description": .string(parameter.description)
            ]
            switch parameter.type {
            case .string, .date:
                entry["type"] = .string("string")
                if parameter.type == .date {
                    entry["format"] = .string("date-time")
                }
            case .integer:
                entry["type"] = .string("integer")
            case .number:
                entry["type"] = .string("number")
            case .boolean:
                entry["type"] = .string("boolean")
            case .stringArray:
                entry["type"] = .string("array")
                entry["items"] = .object(["type": .string("string")])
            }
            if !parameter.allowedValues.isEmpty {
                entry["enum"] = .array(parameter.allowedValues.map { .string($0) })
            }
            properties[parameter.name] = .object(entry)
        }
        return .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(requiredNames.map { .string($0) })
        ])
    }
}

/// A tool as a model sees it. Derived from an `AssistantTool`; carries no behaviour.
struct ToolDefinition: Sendable, Equatable, Hashable, Identifiable {
    var id: String
    /// The name the model calls. Lower snake case, stable — renaming one is a breaking change to
    /// every stored `ToolExecution`.
    var name: String
    var description: String
    var parameters: ToolParameterSchema
    var riskLevel: ToolRiskLevel

    init(
        id: String,
        name: String,
        description: String,
        parameters: ToolParameterSchema = .none,
        riskLevel: ToolRiskLevel = .readOnly
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.parameters = parameters
        self.riskLevel = riskLevel
    }
}

/// Validated arguments handed to a tool.
///
/// A model can produce a string where a number was asked for, or omit an optional field entirely.
/// Rather than let each tool re-litigate that, arguments arrive through typed accessors that either
/// coerce sensibly or throw a `AuraError.toolArgumentsInvalid` naming the offending field.
struct ToolArguments: Sendable, Equatable {
    private let storage: [String: JSONValue]
    private let toolName: String

    init(toolName: String, values: [String: JSONValue] = [:]) {
        self.toolName = toolName
        self.storage = values
    }

    var rawValues: [String: JSONValue] { storage }
    var isEmpty: Bool { storage.isEmpty }

    func jsonString() -> String? { JSONValue.object(storage).jsonString() }

    // MARK: Optional access

    func optionalString(_ name: String) -> String? {
        guard let value = storage[name]?.stringValue else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalInt(_ name: String) -> Int? { storage[name]?.intValue }
    func optionalDouble(_ name: String) -> Double? { storage[name]?.doubleValue }
    func optionalBool(_ name: String) -> Bool? { storage[name]?.boolValue }

    func stringArray(_ name: String) -> [String] {
        if let array = storage[name]?.stringArrayValue { return array }
        // Models frequently send a comma-separated string where an array was requested.
        if let single = optionalString(name) {
            return single
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    func optionalDate(_ name: String, now: Date = Date()) -> Date? {
        guard let raw = optionalString(name) else { return nil }
        return Self.parseDate(raw, now: now)
    }

    // MARK: Required access

    func string(_ name: String) throws -> String {
        guard let value = optionalString(name) else {
            throw AuraError.toolArgumentsInvalid(toolName: toolName, detail: "missing “\(name)”")
        }
        return value
    }

    func int(_ name: String) throws -> Int {
        guard let value = optionalInt(name) else {
            throw AuraError.toolArgumentsInvalid(toolName: toolName, detail: "“\(name)” wasn't a whole number")
        }
        return value
    }

    func double(_ name: String) throws -> Double {
        guard let value = optionalDouble(name) else {
            throw AuraError.toolArgumentsInvalid(toolName: toolName, detail: "“\(name)” wasn't a number")
        }
        return value
    }

    func bool(_ name: String) throws -> Bool {
        guard let value = optionalBool(name) else {
            throw AuraError.toolArgumentsInvalid(toolName: toolName, detail: "“\(name)” wasn't yes or no")
        }
        return value
    }

    func date(_ name: String, now: Date = Date()) throws -> Date {
        guard let value = optionalDate(name, now: now) else {
            throw AuraError.toolArgumentsInvalid(toolName: toolName, detail: "couldn't read a date from “\(name)”")
        }
        return value
    }

    /// Accepts full ISO 8601 with a time, or a bare `yyyy-MM-dd`, which is what models most often
    /// produce for "Friday".
    static func parseDate(_ raw: String, now: Date = Date()) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) { return date }

        let dateOnly = Date.ISO8601FormatStyle(dateSeparator: .dash, timeZone: .current)
            .year().month().day()
        if let date = try? dateOnly.parse(raw) { return date }

        return nil
    }
}

/// Everything a tool is allowed to know about the turn it is running in.
///
/// Deliberately small. A tool receives the identifiers it needs to attribute its work and the clock
/// it should read, and nothing else — no profile, no memory, no conversation transcript. A tool that
/// needs stored data takes the specific store as an injected dependency.
struct ToolExecutionContext: Sendable {
    var conversationID: UUID?
    var messageID: UUID?
    /// `true` when the user's own words in this turn asked for this action. Feeds the confirmation
    /// decision in §34.
    var userExplicitlyRequested: Bool
    /// Injected rather than read from `Date()` so tool behaviour is testable.
    var now: Date
    var iterationIndex: Int

    init(
        conversationID: UUID? = nil,
        messageID: UUID? = nil,
        userExplicitlyRequested: Bool = false,
        now: Date = Date(),
        iterationIndex: Int = 0
    ) {
        self.conversationID = conversationID
        self.messageID = messageID
        self.userExplicitlyRequested = userExplicitlyRequested
        self.now = now
        self.iterationIndex = iterationIndex
    }
}

/// What a tool produces.
///
/// Two audiences, two fields, on purpose. `modelFacingText` grounds the reply; `activityLabel` and
/// `outcomeSummary` are what the user sees. `structuredResult` is there for callers that need the
/// data rather than a description — an App Intent returning a value, or a widget.
struct ToolResult: Sendable, Equatable {
    /// Factual, compact text for the model. No opinions, no filler.
    var modelFacingText: String
    /// Past-tense line for the Activity screen: "Created reminder".
    var activityLabel: String
    /// The specifics: "Order air filter".
    var outcomeSummary: String?
    /// Machine-readable payload for non-conversational callers.
    var structuredResult: JSONValue?
    /// Set when the tool changed something, so the orchestrator knows a refresh is due.
    var didMutateData: Bool

    init(
        modelFacingText: String,
        activityLabel: String,
        outcomeSummary: String? = nil,
        structuredResult: JSONValue? = nil,
        didMutateData: Bool = false
    ) {
        self.modelFacingText = modelFacingText
        self.activityLabel = activityLabel
        self.outcomeSummary = outcomeSummary
        self.structuredResult = structuredResult
        self.didMutateData = didMutateData
    }
}

/// Something AURA can actually do (§33).
///
/// Tools are the only route from a model's intention to a real effect. The rule in §78 —
/// "never claim an action succeeded unless it did" — is enforced structurally: the model never
/// reports outcomes, `ToolExecutor` does, from a returned `ToolResult` or a thrown error.
protocol AssistantTool: Sendable {
    /// Stable internal identifier, e.g. `"memory.search"`.
    var id: String { get }
    /// Model-facing name, e.g. `"search_memory"`.
    var name: String { get }
    /// Written for the model: when to reach for this, and when not to.
    var description: String { get }
    var parameters: ToolParameterSchema { get }
    /// System authorizations this tool needs before it can run.
    var requiredPermissions: Set<AuraPermission> { get }
    var riskLevel: ToolRiskLevel { get }
    /// Forces confirmation regardless of tier. Use for a tool whose tier understates its blast
    /// radius in some configurations.
    var alwaysRequiresConfirmation: Bool { get }
    /// `false` when the tool needs the network, so it can be withheld while offline (§54).
    var worksOffline: Bool { get }

    /// `true` when a *partial* grant of `requiredPermissions` is not enough.
    ///
    /// EventKit is why this exists. iOS can grant write-only calendar access: AURA may add an event but
    /// cannot see the calendar. That is genuinely usable for `create_calendar_event` and genuinely useless
    /// for `read_calendar` — a read under it returns an empty array, indistinguishable from a clear day.
    /// Without this flag a read tool would be offered to the model and then refused, which is exactly the
    /// promise-then-refuse pattern §78 rules out.
    var requiresFullPermissionAccess: Bool { get }

    /// Present-tense progress line shown while this runs: "Checking your calendar".
    func progressLabel(for arguments: ToolArguments) -> String

    /// The sentence the user is asked to approve, for tools that need confirmation.
    /// Must state the concrete effect, not the tool's name.
    func confirmationPrompt(for arguments: ToolArguments) -> String

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult
}

extension AssistantTool {
    var requiredPermissions: Set<AuraPermission> { [] }
    var alwaysRequiresConfirmation: Bool { false }
    var worksOffline: Bool { true }
    /// Most tools are fine with whatever the user granted; only the ones that would silently see nothing
    /// need to insist on full access.
    var requiresFullPermissionAccess: Bool { false }

    var definition: ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            description: description,
            parameters: parameters,
            riskLevel: riskLevel
        )
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Working on it"
    }

    func confirmationPrompt(for arguments: ToolArguments) -> String {
        "Go ahead with \(name.replacingOccurrences(of: "_", with: " "))?"
    }

    /// Whether this invocation needs the user's say-so.
    func requiresConfirmation(context: ToolExecutionContext) -> Bool {
        if alwaysRequiresConfirmation { return true }
        return riskLevel.requiresConfirmation(
            userExplicitlyRequested: context.userExplicitlyRequested
        )
    }

    /// Coerces a provider's raw arguments into this tool's `ToolArguments`.
    func makeArguments(from raw: [String: JSONValue]) -> ToolArguments {
        ToolArguments(toolName: name, values: raw)
    }
}
