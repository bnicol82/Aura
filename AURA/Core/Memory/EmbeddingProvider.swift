import Foundation

/// A text embedding.
struct EmbeddingVector: Sendable, Equatable, Hashable {
    var values: [Float]
    /// Which model produced it. Vectors from different models are not comparable, so a stored vector
    /// whose `modelIdentifier` no longer matches the active provider must be re-embedded rather than
    /// silently compared.
    var modelIdentifier: String

    init(values: [Float], modelIdentifier: String) {
        self.values = values
        self.modelIdentifier = modelIdentifier
    }

    var dimension: Int { values.count }

    /// Cosine similarity, in -1...1. Returns 0 for mismatched models or a zero vector, which keeps a
    /// bad comparison out of the ranking rather than letting it produce a confident wrong answer.
    func cosineSimilarity(to other: EmbeddingVector) -> Double {
        guard modelIdentifier == other.modelIdentifier,
              values.count == other.values.count,
              !values.isEmpty
        else { return 0 }

        var dot: Double = 0
        var lhsMagnitude: Double = 0
        var rhsMagnitude: Double = 0
        for index in values.indices {
            let lhs = Double(values[index])
            let rhs = Double(other.values[index])
            dot += lhs * rhs
            lhsMagnitude += lhs * lhs
            rhsMagnitude += rhs * rhs
        }
        guard lhsMagnitude > 0, rhsMagnitude > 0 else { return 0 }
        return dot / (lhsMagnitude.squareRoot() * rhsMagnitude.squareRoot())
    }
}

/// Turns text into vectors for semantic search (§31).
///
/// ### Why nothing calls this in V1
/// The specification is explicit that V1 must not depend on embeddings, and especially not on a
/// cloud embedding provider — keyword, entity and metadata search over SwiftData carry V1 on their
/// own. The abstraction exists now so that `MemoryItem.embeddingReference` has a defined meaning and
/// V2 can add vectors without a schema migration or a change to the ranking interface.
///
/// `MemoryRelevanceScore.semanticSimilarity` is therefore always 0 today, weighted and ready.
protocol EmbeddingProvider: Sendable {
    /// Identifies the model, and therefore the vector space.
    var modelIdentifier: String { get }
    var dimension: Int { get }
    var isOnDevice: Bool { get }

    func availability() async -> ModelAvailability

    func embed(_ text: String) async throws -> EmbeddingVector

    /// Batch form. Providers with per-call overhead should override the default.
    func embed(batch texts: [String]) async throws -> [EmbeddingVector]
}

extension EmbeddingProvider {
    func embed(batch texts: [String]) async throws -> [EmbeddingVector] {
        var results: [EmbeddingVector] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            results.append(try await embed(text))
        }
        return results
    }
}

/// The V1 embedding provider: none.
///
/// A null object rather than an optional dependency, so calling code never branches on whether
/// embeddings exist. It reports `.notConfigured` and refuses to invent vectors — returning zeros
/// would make every memory look equally similar to every query, which is worse than no signal at all.
struct UnavailableEmbeddingProvider: EmbeddingProvider {
    var modelIdentifier: String { "none" }
    var dimension: Int { 0 }
    var isOnDevice: Bool { true }

    func availability() async -> ModelAvailability { .notConfigured }

    func embed(_ text: String) async throws -> EmbeddingVector {
        throw AuraError.providerNotConfigured(providerName: "Semantic search")
    }
}
