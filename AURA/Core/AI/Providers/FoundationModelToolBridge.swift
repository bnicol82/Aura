import FoundationModels
import Foundation

/// Presents AURA's tools to Apple's on-device model, and routes its calls back through the gates
/// (§33, §34).
///
/// ### Why an adapter rather than making tools conform to Apple's protocol directly
/// `FoundationModels.Tool` is generic over a `Generable` `Arguments` type, which means a conforming
/// tool has to declare its argument shape at compile time. AURA's tools declare theirs as data — a
/// `ToolParameterSchema` — because the same declaration also has to render as JSON Schema for cloud
/// providers and as a form for the confirmation UI. Conforming directly would mean writing every
/// tool's parameters twice and keeping them in step by hand.
///
/// So there is exactly one adapter type, with `Arguments = GeneratedContent`: the dynamic shape. The
/// schema is built at runtime from the tool's declaration, and the arguments arrive as generated
/// content that is decoded into `[String: JSONValue]` — the currency `ToolArguments` already speaks.
///
/// ### The invariant this file exists to preserve
/// Apple's framework calls tools *itself*, inside `LanguageModelSession`, without returning control.
/// That is precisely the path on which safety checks could be bypassed. The adapter therefore holds a
/// `ToolInvoking` handle rather than a tool: it cannot reach a tool's `execute` directly even if it
/// tried, so every model-initiated call goes through `DefaultToolExecutor`'s gates.
///
/// ### APIs verified against Apple's documentation before use
/// | API | Verified shape |
/// |---|---|
/// | `protocol Tool<Arguments, Output>: Sendable` | `Arguments: ConvertibleFromGeneratedContent`, `Output: PromptRepresentable` |
/// | `Tool.call(arguments:)` | `func call(arguments: Self.Arguments) async throws -> Self.Output` |
/// | `Tool` properties | `name`, `description`, `parameters: GenerationSchema`, `includesSchemaInInstructions: Bool` |
/// | `GeneratedContent` | conforms to `ConvertibleFromGeneratedContent`; `var jsonString: String` |
/// | `GenerationSchema.init(root:dependencies:)` | `throws`, both required |
/// | `DynamicGenerationSchema.init(name:description:properties:)` | all three; `description` is `String?` |
/// | `DynamicGenerationSchema.Property.init(name:description:schema:isOptional:)` | all four |
/// | `DynamicGenerationSchema.init(type:guides:)` | `where Value: Generable`; `guides` defaults to `[]` |
/// | `DynamicGenerationSchema.init(arrayOf:minimumElements:maximumElements:)` | last two default to `nil` |
/// | `GenerationGuide.anyOf(_:)` | `static func anyOf([String]) -> GenerationGuide<String>` |
/// | `String`, `Int`, `Double`, `Bool` | all conform to `Generable` |
/// | `Transcript.ToolDefinition.init(tool:)` | `init(tool: some Tool)` |
enum FoundationModelToolBridge {

    /// Builds the adapters for one request.
    ///
    /// A tool whose schema will not build is *omitted* rather than allowed to fail the turn. That is the
    /// safe direction: the model simply cannot reach a capability, which it handles the same way it
    /// handles a tool that was withheld for a missing permission. The alternative — a whole conversation
    /// failing because one parameter list was malformed — is worse for the user and no safer.
    static func adapters(
        for definitions: [ToolDefinition],
        invoker: any ToolInvoking,
        activity: ToolActivityCollector
    ) -> [any Tool] {
        definitions.compactMap { definition in
            do {
                return AURAToolAdapter(
                    name: definition.name,
                    description: definition.description,
                    parameters: try schema(for: definition),
                    invoker: invoker,
                    activity: activity
                )
            } catch {
                AuraLog.tools.error(
                    """
                    Withholding tool \(definition.name, privacy: .public) — its schema would not build: \
                    \(error.localizedDescription, privacy: .public)
                    """
                )
                return nil
            }
        }
    }

    // MARK: - Schema

    /// Renders a tool's declared parameters as a `GenerationSchema`.
    ///
    /// `dependencies` is empty because every leaf is a primitive or an array of them: AURA's tools take
    /// flat argument lists on purpose, since a model filling a nested object reliably is a much taller
    /// order than one filling four named fields. If a tool ever needs a nested type, its sub-schema goes
    /// in `dependencies` and is referenced by name via `init(referenceTo:)`.
    static func schema(for definition: ToolDefinition) throws -> GenerationSchema {
        let properties = definition.parameters.parameters.map { parameter in
            DynamicGenerationSchema.Property(
                name: parameter.name,
                description: parameter.description,
                schema: leafSchema(for: parameter),
                // Inverted rather than passed through: AURA declares what is *required*, Apple asks what
                // is optional. Getting this backwards would make every required argument droppable.
                isOptional: !parameter.isRequired
            )
        }

        return try GenerationSchema(
            root: DynamicGenerationSchema(
                name: definition.name,
                description: definition.description,
                properties: properties
            ),
            dependencies: []
        )
    }

    /// The schema for one parameter.
    ///
    /// `allowedValues` is checked first and wins over the declared type, because a constrained set is
    /// always a set of strings on the wire — a tool declaring `type: .integer` with `allowedValues`
    /// would otherwise get the constraint silently dropped.
    ///
    /// `.date` maps to a plain string: no provider has a date type, which is why `ToolParameter.date`
    /// is documented as "ISO 8601 text with a contract" and `ToolArguments.optionalDate` parses it.
    static func leafSchema(for parameter: ToolParameter) -> DynamicGenerationSchema {
        if !parameter.allowedValues.isEmpty {
            return DynamicGenerationSchema(type: String.self, guides: [.anyOf(parameter.allowedValues)])
        }
        switch parameter.type {
        case .string, .date:
            return DynamicGenerationSchema(type: String.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .stringArray:
            return DynamicGenerationSchema(arrayOf: DynamicGenerationSchema(type: String.self))
        }
    }

    // MARK: - Arguments

    /// Decodes Apple's generated content into AURA's argument currency.
    ///
    /// Via `jsonString` rather than by walking `GeneratedContent.Kind`, for two reasons. It is one
    /// documented property against a `JSONValue` decoder that already exists and is tested, instead of a
    /// hand-written traversal of an enum Apple may extend. And a model that produces a number where a
    /// string was asked for lands in `JSONValue` faithfully, where `ToolArguments`' coercing accessors
    /// deal with it — that coercion exists precisely because models do this constantly.
    ///
    /// An empty dictionary on failure rather than a throw: the tool's own required-argument check
    /// produces a message naming the missing field, which is far more useful to the model than
    /// "arguments could not be parsed".
    static func decodeArguments(_ content: GeneratedContent) -> [String: JSONValue] {
        guard let value = JSONValue(jsonString: content.jsonString),
              let object = value.objectValue
        else {
            AuraLog.tools.error("Could not decode tool arguments from generated content.")
            return [:]
        }
        return object
    }

}

/// Gathers the activity notes produced during one generation.
///
/// Needed because of the same platform fact that makes the adapter necessary: Apple's session calls
/// tools from inside `respond`/`streamResponse`, so a note is produced at a point with no way to yield
/// out to the provider's event stream. This collects them where they happen so the provider can attach
/// them to the response it returns.
///
/// Without it the transcript would show an answer that changed something in the world with no record
/// of the change — which is exactly what §36's audit trail is for.
actor ToolActivityCollector {

    private var notes: [ToolActivityNote] = []

    func record(_ note: ToolActivityNote) {
        notes.append(note)
    }

    /// Takes the notes and empties the collector.
    ///
    /// Draining rather than reading is what makes a collector reusable across the retry inside
    /// `stream`: a second attempt must not report the first attempt's actions a second time.
    func drain() -> [ToolActivityNote] {
        defer { notes = [] }
        return notes
    }
}

/// One tool, in the shape `LanguageModelSession` can call.
///
/// A `struct` because `Tool` requires `Sendable` and there is no per-call state: the schema is built
/// once when the request is assembled, and everything else lives behind the `ToolInvoking` handle.
struct AURAToolAdapter: Tool {

    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema

    /// `true` so the model is shown the argument shape it has to fill.
    ///
    /// Costs prompt tokens and earns them back: the on-device model is much likelier to produce a
    /// complete, correctly-named argument set when it can see the schema, and a call with a missing
    /// required field is a wasted round trip that ends in an error the user sees.
    let includesSchemaInInstructions = true

    /// A handle, deliberately not the tool. The adapter cannot reach `AssistantTool.execute` even if it
    /// wanted to, so it cannot route around the permission, offline, risk-ceiling and confirmation
    /// gates in `DefaultToolExecutor`.
    private let invoker: any ToolInvoking

    /// Where this call's activity note goes, since there is no stream to yield it into from here.
    private let activity: ToolActivityCollector

    init(
        name: String,
        description: String,
        parameters: GenerationSchema,
        invoker: any ToolInvoking,
        activity: ToolActivityCollector
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.invoker = invoker
        self.activity = activity
    }

    func call(arguments: GeneratedContent) async throws -> String {
        do {
            let outcome = try await invoker.invokeTool(
                named: name,
                arguments: FoundationModelToolBridge.decodeArguments(arguments)
            )
            await activity.record(outcome.activity)
            return outcome.modelFacingText
        } catch let error as CancellationError {
            // Rethrown, not reported: the user cancelled the turn, so there is nobody to tell and no
            // reply to ground. Swallowing it would leave generation running after a cancel.
            throw error
        } catch {
            // A failed attempt is still something AURA did, and the transcript says so. Recording only
            // successes would make the Activity log a highlight reel (§36). The wording is shared with the
            // orchestrator-managed path so a failure reads identically whoever ran the tool.
            let outcome = ToolInvocationOutcome.failure(toolName: name, error: error)
            await activity.record(outcome.activity)
            return outcome.modelFacingText
        }
    }
}
