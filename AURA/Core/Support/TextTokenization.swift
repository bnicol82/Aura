import Foundation

extension String {
    /// Splits text into lower-cased search terms, dropping punctuation, stop words, and one-letter
    /// fragments.
    ///
    /// This is the tokenizer behind V1's keyword retrieval (§31). It is deliberately simple and
    /// dependency-free: `NaturalLanguage` gives better linguistic analysis and is used for entity
    /// recognition during extraction, but tokenizing a query for keyword overlap does not need a
    /// tagger, and this way ranking stays a pure, fast, testable function.
    func keywordTokens(minimumLength: Int = 2) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        var seen = Set<String>()
        var tokens: [String] = []

        for raw in lowercased().components(separatedBy: separators) {
            guard raw.count >= minimumLength else { continue }
            guard !TextTokenization.stopWords.contains(raw) else { continue }
            guard seen.insert(raw).inserted else { continue }
            tokens.append(raw)
        }
        return tokens
    }

    /// Capitalised words that look like proper nouns, used as a cheap entity signal.
    ///
    /// Sentence-initial words are skipped because every sentence starts capitalised. This is a
    /// heuristic, not recognition — `NaturalLanguage`'s `NLTagger` does the real work during
    /// extraction, and this exists so retrieval can weight entities without loading a tagger.
    func likelyProperNouns() -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        for sentence in components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
            let words = sentence
                .components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
                .filter { !$0.isEmpty }

            for (index, word) in words.enumerated() {
                guard index > 0 else { continue }
                guard let first = word.first, first.isUppercase else { continue }
                guard word.count > 1 else { continue }
                guard !TextTokenization.commonCapitalizedWords.contains(word.lowercased()) else { continue }
                guard seen.insert(word.lowercased()).inserted else { continue }
                results.append(word)
            }
        }
        return results
    }

    /// Trimmed, whitespace-collapsed text. Used everywhere user input reaches storage.
    var normalizedWhitespace: String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum TextTokenization {
    /// English stop words. Kept short on purpose — an aggressive list strips terms that matter in
    /// this domain ("no", "not", "own" all change meaning in a personal-memory context).
    static let stopWords: Set<String> = [
        "the", "and", "for", "are", "but", "was", "were", "with", "that", "this", "from",
        "have", "has", "had", "you", "your", "yours", "our", "ours", "its", "his", "her",
        "hers", "their", "them", "they", "she", "him", "who", "whom", "what", "when",
        "where", "which", "how", "why", "can", "could", "would", "should", "will", "shall",
        "did", "does", "done", "been", "being", "than", "then", "there", "here", "into",
        "onto", "out", "off", "over", "under", "again", "about", "also", "just", "very",
        "some", "any", "all", "each", "more", "most", "much", "many", "such", "only",
        "own", "same", "too", "get", "got", "let", "put", "say", "said", "tell", "told"
    ]

    /// Capitalised words that are almost never entities in this app's conversations.
    static let commonCapitalizedWords: Set<String> = [
        "i", "i'm", "i'll", "i've", "ok", "okay", "yes", "no", "monday", "tuesday",
        "wednesday", "thursday", "friday", "saturday", "sunday", "today", "tomorrow",
        "yesterday", "tonight", "morning", "afternoon", "evening"
    ]

    /// Overlap between two token sets, normalised 0...1 against the query.
    ///
    /// Normalising by the *query* rather than by the union matters: a long stored memory that happens
    /// to contain every query term should score 1, not be penalised for having extra words.
    static func overlapScore(queryTokens: [String], documentText: String) -> Double {
        guard !queryTokens.isEmpty else { return 0 }
        let haystack = documentText.lowercased()
        let hits = queryTokens.reduce(into: 0) { total, token in
            if haystack.contains(token) { total += 1 }
        }
        return Double(hits) / Double(queryTokens.count)
    }
}
