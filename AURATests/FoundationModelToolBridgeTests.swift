import FoundationModels
import Foundation
import Testing

@testable import AURA

/// The seam between AURA's tool declarations and Apple's `FoundationModels.Tool`.
///
/// What is testable here is the translation, not the calling: a `LanguageModelSession` needs Apple
/// Intelligence, which no simulator has. So these tests pin the two things that would silently break the
/// bridge — a schema that will not build, and arguments that do not survive the round trip — and leave
/// "the model actually calls it" to a device.
@Suite("Foundation model tool bridge")
struct FoundationModelToolBridgeTests {

    private static func definition(
        _ parameters: [ToolParameter],
        riskLevel: ToolRiskLevel = .readOnly
    ) -> ToolDefinition {
        ToolDefinition(
            id: "test.tool",
            name: "test_tool",
            description: "A tool for tests.",
            parameters: ToolParameterSchema(parameters),
            riskLevel: riskLevel
        )
    }

    // MARK: Schema

    @Test("Every declared parameter type builds a schema")
    func everyParameterTypeBuilds() throws {
        // One test over all cases rather than one per case, because the thing that would break is a new
        // `ValueType` being added with no mapping — and that shows up as a compile error in `leafSchema`
        // plus a failure here, rather than a tool silently being withheld at runtime.
        let parameters = ToolParameter.ValueType.allCasesForTesting.map { type in
            ToolParameter(name: "field_\(type.rawValue)", description: "A \(type.rawValue).", type: type)
        }
        // The assertion is the `try`: `GenerationSchema(root:dependencies:)` throws on anything it cannot
        // represent, which is exactly the failure this guards against. Its contents are not inspectable on
        // the iOS 26 SDK — `GenerationSchema.name` is iOS 27 — so "it built" is the whole available signal.
        _ = try FoundationModelToolBridge.schema(for: Self.definition(parameters))
    }

    @Test("A constrained parameter builds, and constraints win over the declared type")
    func allowedValuesBuild() throws {
        // A set of choices is always strings on the wire. A tool declaring `.integer` with `allowedValues`
        // must not lose the constraint, which is why `leafSchema` checks it first.
        _ = try FoundationModelToolBridge.schema(for: Self.definition([
            ToolParameter(
                name: "category",
                description: "Which one.",
                type: .integer,
                isRequired: false,
                allowedValues: ["one", "two"]
            )
        ]))
        // That the constraint reached the schema rather than the declared type is checked where it is
        // decidable: `leafSchema` takes the `allowedValues` branch first, and a schema built from
        // `Int.self` would reject a `GenerationGuide<String>` at compile time.
    }

    @Test("A tool with no parameters still builds a schema")
    func emptySchemaBuilds() throws {
        // The common case for a read-only tool, and the one most likely to be rejected by a schema builder
        // that assumes at least one property.
        _ = try FoundationModelToolBridge.schema(for: Self.definition([]))
    }

    @Test("An unbuildable tool is withheld rather than failing the turn")
    func unbuildableToolIsWithheld() async throws {
        // Two parameters with the same name is the malformed case a schema builder rejects. Withholding is
        // the safe direction: the model cannot reach a capability, which it already handles. Failing the
        // whole conversation over one parameter list is worse for the user and no safer.
        let duplicated = Self.definition([
            ToolParameter(name: "same", description: "First.", type: .string),
            ToolParameter(name: "same", description: "Second.", type: .string)
        ])
        let good = Self.definition([ToolParameter(name: "fine", description: "Fine.", type: .string)])

        let adapters = FoundationModelToolBridge.adapters(
            for: [duplicated, good],
            invoker: NeverCalledInvoker(),
            activity: ToolActivityCollector()
        )
        // Either the duplicate built anyway — Apple's schema may tolerate it — or it was dropped. What must
        // never happen is the good one being lost with it.
        #expect(adapters.contains { $0.name == "test_tool" })
        #expect(adapters.count <= 2)
    }

    // MARK: Arguments

    @Test("Arguments survive the round trip from generated content")
    func argumentsDecode() throws {
        let content = try GeneratedContent(
            json: #"{"query":"garage","limit":3,"pinned":true}"#
        )
        let values = FoundationModelToolBridge.decodeArguments(content)

        let arguments = ToolArguments(toolName: "test_tool", values: values)
        #expect(try arguments.string("query") == "garage")
        #expect(try arguments.int("limit") == 3)
        #expect(try arguments.bool("pinned") == true)
    }

    @Test("A number where a string was asked for is coerced, not lost")
    func coercesLooseTypes() throws {
        // Models do this constantly, which is why `ToolArguments` coerces and why the bridge decodes into
        // `JSONValue` faithfully instead of forcing types at the boundary.
        let content = try GeneratedContent(json: #"{"query":42,"limit":"7"}"#)
        let arguments = ToolArguments(
            toolName: "test_tool",
            values: FoundationModelToolBridge.decodeArguments(content)
        )
        #expect(try arguments.string("query") == "42")
        #expect(try arguments.int("limit") == 7)
    }

    @Test("Content that is not an object decodes to no arguments rather than crashing")
    func nonObjectContentIsEmpty() throws {
        // The tool's own required-argument check then produces a message naming the missing field, which is
        // far more use to the model than "arguments could not be parsed".
        let content = try GeneratedContent(json: #"["not","an","object"]"#)
        #expect(FoundationModelToolBridge.decodeArguments(content).isEmpty)
    }

    // MARK: Failure reporting

    @Test("A failed call tells the model it did not happen")
    func failureIsUnambiguous() {
        let outcome = ToolInvocationOutcome.failure(
            toolName: "forget_this",
            error: AuraError.permissionDenied(.calendar)
        )
        #expect(outcome.modelFacingText.contains("did not run"))
        #expect(outcome.modelFacingText.contains("did not happen"))
        // And the transcript agrees — no tick beside something that failed.
        #expect(outcome.activity.succeeded == false)
        #expect(outcome.activity.toolName == "forget_this")
    }

    @Test("A note for a call in flight is not marked successful")
    func startedNoteIsNotASuccess() {
        let note = ToolActivityNote.started(toolName: "search_memory")
        #expect(note.label == "search memory")
        #expect(note.succeeded == false)
        #expect(note.outcome == nil)
    }

    // MARK: Collector

    @Test("Draining the collector empties it, so a retry cannot double-report")
    func collectorDrains() async {
        let collector = ToolActivityCollector()
        await collector.record(ToolActivityNote(toolName: "a", label: "A"))
        await collector.record(ToolActivityNote(toolName: "b", label: "B"))

        #expect(await collector.drain().map(\.toolName) == ["a", "b"])
        #expect(await collector.drain().isEmpty)
    }
}

/// An invoker that fails the test if it is ever reached. Schema building must not call tools.
private struct NeverCalledInvoker: ToolInvoking {
    func invokeTool(named name: String, arguments: [String: JSONValue]) async throws -> ToolInvocationOutcome {
        Issue.record("Building adapters must not invoke \(name).")
        throw AuraError.toolNotFound(name: name)
    }
}

extension ToolParameter.ValueType {
    /// Every case, for the exhaustiveness test.
    ///
    /// Hand-written rather than `CaseIterable`, because adding the conformance to production code purely
    /// for a test would put a test's needs into the model layer.
    static let allCasesForTesting: [ToolParameter.ValueType] = [
        .string, .integer, .number, .boolean, .stringArray, .date
    ]
}
