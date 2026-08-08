import Foundation
import Testing

@testable import AURA

@Suite("Tool safety tiers")
struct ToolRiskLevelTests {

    @Test("Read-only tools never need confirmation")
    func readOnlyNeverConfirms() {
        #expect(!ToolRiskLevel.readOnly.requiresConfirmation(userExplicitlyRequested: true))
        #expect(!ToolRiskLevel.readOnly.requiresConfirmation(userExplicitlyRequested: false))
    }

    @Test("Reversible tools run when asked for, and confirm when the model volunteered them")
    func reversibleDependsOnOrigin() {
        #expect(!ToolRiskLevel.reversible.requiresConfirmation(userExplicitlyRequested: true))
        #expect(ToolRiskLevel.reversible.requiresConfirmation(userExplicitlyRequested: false))
    }

    @Test("Consequential tools always confirm, even when the user asked outright")
    func consequentialAlwaysConfirms() {
        #expect(ToolRiskLevel.consequential.requiresConfirmation(userExplicitlyRequested: true))
        #expect(ToolRiskLevel.consequential.requiresConfirmation(userExplicitlyRequested: false))
    }

    @Test("Tiers order from least to most dangerous")
    func tiersAreOrdered() {
        #expect(ToolRiskLevel.readOnly < ToolRiskLevel.reversible)
        #expect(ToolRiskLevel.reversible < ToolRiskLevel.consequential)
    }

    @Test("A tool may escalate beyond its tier but never below it")
    func alwaysRequiresConfirmationOverrides() {
        let tool = StubTool(id: "stub.read", name: "stub_read", riskLevel: .readOnly, alwaysConfirms: true)
        #expect(tool.requiresConfirmation(context: ToolExecutionContext(userExplicitlyRequested: true)))
    }
}

@Suite("Tool registry")
struct ToolRegistryTests {

    private func makeRegistry() -> ToolRegistry {
        ToolRegistry(tools: [
            StubTool(id: "memory.search", name: "search_memory", riskLevel: .readOnly),
            StubTool(id: "calendar.read", name: "read_calendar", riskLevel: .readOnly, permissions: [.calendar]),
            StubTool(id: "reminder.create", name: "create_reminder", riskLevel: .reversible, permissions: [.reminders]),
            StubTool(id: "weather.lookup", name: "lookup_weather", riskLevel: .readOnly, worksOffline: false),
            StubTool(id: "memory.deleteAll", name: "delete_all_memories", riskLevel: .consequential)
        ])
    }

    @Test("Everything registers and is retrievable by id and by model-facing name")
    func lookup() async {
        let registry = makeRegistry()
        #expect(await registry.allTools.count == 5)
        #expect(await registry.tool(id: "memory.search")?.name == "search_memory")
        #expect(await registry.tool(named: "search_memory")?.id == "memory.search")
        #expect(await registry.tool(named: "does_not_exist") == nil)
    }

    @Test("A tool whose permission is missing is withheld rather than offered and failed")
    func filtersByPermission() async {
        let registry = makeRegistry()
        let criteria = ToolRegistry.AvailabilityCriteria(
            grantedPermissions: [.calendar],
            isOnline: true,
            maximumRiskLevel: .consequential
        )
        let ids = await Set(registry.availableTools(for: criteria).map(\.id))

        #expect(ids.contains("calendar.read"))
        #expect(!ids.contains("reminder.create"))
    }

    @Test("Network-dependent tools are withheld while offline")
    func filtersByConnectivity() async {
        let registry = makeRegistry()
        var criteria = ToolRegistry.AvailabilityCriteria.unrestricted
        criteria.isOnline = false

        let ids = await Set(registry.availableTools(for: criteria).map(\.id))
        #expect(!ids.contains("weather.lookup"))
        #expect(ids.contains("memory.search"))
    }

    @Test("An unattended entry point gets read-only tools only")
    func unattendedIsReadOnly() async {
        let registry = makeRegistry()
        let tools = await registry.availableTools(for: .unattended)

        #expect(tools.allSatisfy { $0.riskLevel == .readOnly })
        // Offline and unpermissioned, so only the memory search survives.
        #expect(tools.map(\.id) == ["memory.search"])
    }

    @Test("Unavailable tools come back with a reason a person could act on")
    func explainsUnavailability() async {
        let registry = makeRegistry()
        let reasons = await registry.unavailableTools(for: .unattended)
        let byID = Dictionary(uniqueKeysWithValues: reasons.map { ($0.tool.id, $0.reason) })

        #expect(byID["weather.lookup"]?.contains("internet") == true)
        #expect(byID["memory.deleteAll"]?.contains("confirm") == true)
        #expect(byID["calendar.read"]?.contains("Calendar") == true)
    }

    @Test("Re-registering an id replaces the tool without orphaning its old name")
    func replacesByID() async {
        let registry = ToolRegistry()
        await registry.register(StubTool(id: "a", name: "first_name", riskLevel: .readOnly))
        await registry.register(StubTool(id: "a", name: "second_name", riskLevel: .readOnly))

        #expect(await registry.allTools.count == 1)
        #expect(await registry.tool(named: "second_name")?.id == "a")
        #expect(await registry.tool(named: "first_name") == nil)
    }

    @Test("Definitions render for the model with names, descriptions and tiers intact")
    func rendersDefinitions() async {
        let registry = makeRegistry()
        let definitions = await registry.availableDefinitions(for: .unrestricted)

        #expect(definitions.count == 5)
        #expect(definitions.allSatisfy { !$0.name.isEmpty && !$0.description.isEmpty })
        #expect(definitions.first { $0.id == "memory.deleteAll" }?.riskLevel == .consequential)
    }
}

@Suite("Tool arguments")
struct ToolArgumentsTests {

    @Test("Required values are read, and missing ones throw with the field named")
    func requiredValues() throws {
        let arguments = ToolArguments(toolName: "create_reminder", values: [
            "title": .string("Order an air filter"),
            "priority": .number(2),
            "urgent": .bool(true)
        ])

        #expect(try arguments.string("title") == "Order an air filter")
        #expect(try arguments.int("priority") == 2)
        #expect(try arguments.bool("urgent") == true)

        #expect(throws: AuraError.self) { _ = try arguments.string("missing") }
    }

    @Test("Numbers sent as strings are coerced rather than rejected")
    func coercesLooseTypes() throws {
        let arguments = ToolArguments(toolName: "t", values: [
            "count": .string("7"),
            "flag": .string("yes")
        ])

        #expect(try arguments.int("count") == 7)
        #expect(try arguments.bool("flag") == true)
    }

    @Test("A comma-separated string is accepted where an array was requested")
    func coercesStringToArray() {
        let arguments = ToolArguments(toolName: "t", values: [
            "tags": .string("garage, renovation , october")
        ])
        #expect(arguments.stringArray("tags") == ["garage", "renovation", "october"])
    }

    @Test("Blank strings read as absent, not as empty values")
    func blankIsAbsent() {
        let arguments = ToolArguments(toolName: "t", values: ["title": .string("   ")])
        #expect(arguments.optionalString("title") == nil)
    }

    @Test("Both full ISO 8601 and bare calendar dates parse")
    func parsesDates() throws {
        let full = try #require(ToolArguments.parseDate("2026-05-06T14:30:00Z"))
        let bare = try #require(ToolArguments.parseDate("2026-05-06"))

        let calendar = Calendar(identifier: .gregorian)
        #expect(calendar.component(.year, from: full) == 2026)
        #expect(calendar.component(.year, from: bare) == 2026)
        #expect(ToolArguments.parseDate("next Friday") == nil)
    }

    @Test("JSON Schema rendering marks required fields and enum constraints")
    func rendersJSONSchema() throws {
        let schema = ToolParameterSchema([
            ToolParameter(name: "query", description: "What to search for", type: .string),
            ToolParameter(name: "limit", description: "How many", type: .integer, isRequired: false),
            ToolParameter(name: "scope", description: "Where to look", type: .string, isRequired: false, allowedValues: ["memories", "conversations"])
        ])

        let rendered = try #require(schema.jsonSchema().objectValue)
        #expect(rendered["type"]?.stringValue == "object")

        let required = try #require(rendered["required"]?.stringArrayValue)
        #expect(required == ["query"])

        let properties = try #require(rendered["properties"]?.objectValue)
        #expect(properties["limit"]?.objectValue?["type"]?.stringValue == "integer")
        #expect(properties["scope"]?.objectValue?["enum"]?.stringArrayValue == ["memories", "conversations"])
    }
}

// MARK: - Test double

/// A tool that records what it was called with and returns a fixed result.
private struct StubTool: AssistantTool {
    let id: String
    let name: String
    var description: String { "Stub tool for tests." }
    var parameters: ToolParameterSchema { .none }
    let riskLevel: ToolRiskLevel
    var requiredPermissions: Set<AuraPermission>
    var alwaysRequiresConfirmation: Bool
    var worksOffline: Bool

    init(
        id: String,
        name: String,
        riskLevel: ToolRiskLevel,
        permissions: Set<AuraPermission> = [],
        alwaysConfirms: Bool = false,
        worksOffline: Bool = true
    ) {
        self.id = id
        self.name = name
        self.riskLevel = riskLevel
        self.requiredPermissions = permissions
        self.alwaysRequiresConfirmation = alwaysConfirms
        self.worksOffline = worksOffline
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        ToolResult(
            modelFacingText: "stub ran",
            activityLabel: "Ran \(name)",
            outcomeSummary: nil
        )
    }
}
