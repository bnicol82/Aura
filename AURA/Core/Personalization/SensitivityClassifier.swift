import Foundation

/// Decides when the assistant should stop being funny (§12).
///
/// Runs before any model call and works entirely on the device with no dependencies. That matters:
/// asking a model "is this sensitive?" costs a round trip on every turn, and a network failure or an
/// unavailable model must not be able to leave humour switched on during a conversation about
/// someone's health.
///
/// The classifier errs toward seriousness. A false positive costs one flat answer; a false negative
/// costs a joke about a diagnosis.
struct SensitivityClassifier: Sendable {

    init() {}

    func classify(_ text: String) -> SensitivityMode {
        let haystack = " \(text.lowercased().normalizedWhitespace) "

        if Self.urgentPhrases.contains(where: { haystack.contains($0) }) {
            return .urgent
        }
        if Self.sensitivePhrases.contains(where: { haystack.contains($0) }) {
            return .sensitive
        }
        return .normal
    }

    /// Combines the text signal with the categories retrieval pulled in.
    ///
    /// Needed because a follow-up can be sensitive without saying so: "what did the doctor say
    /// again?" is innocuous in isolation, but the memory it retrieves is a health record. Taking the
    /// stronger of the two signals keeps the gear change from slipping between turns.
    func classify(
        text: String,
        retrievedCategories: Set<MemoryCategory>
    ) -> SensitivityMode {
        let textual = classify(text)
        if textual == .urgent { return .urgent }
        if retrievedCategories.contains(where: \.isSensitive) { return .sensitive }
        return textual
    }

    /// Phrases suggesting immediate danger.
    ///
    /// Padded with spaces at both ends where a bare substring would over-match — " hurt " will not
    /// fire on "hurting for time", and "911" will not fire on a street number.
    private static let urgentPhrases: [String] = [
        "call 911", "call an ambulance", "emergency room", " er right now",
        "chest pain", "can't breathe", "cannot breathe", "trouble breathing",
        "overdose", "suicidal", "kill myself", "hurt myself", "self harm",
        "bleeding badly", "unconscious", "not breathing", "heart attack",
        "stroke symptoms", "poisoned", "house is on fire", "break-in", "broke in",
        "car accident", "she collapsed", "he collapsed", "they collapsed"
    ]

    /// Subjects that call for a serious register: health, money, legal, security, death, family
    /// difficulty. Substrings, so "diagnosis" matches "diagnosis," and "diagnoses".
    private static let sensitivePhrases: [String] = [
        // Health
        "diagnos", "symptom", "prescription", "medication", "surgery", "biopsy",
        "chemo", "oncolog", "cardiolog", "blood pressure", "blood test", "mri",
        "therapist", "therapy", "depress", "anxiety", "mental health", "hospital",
        "cancer", "tumor", "tumour", "illness", "chronic", "insulin", "dosage",
        "side effect", "specialist appointment",
        // Money
        "mortgage", "refinanc", "retirement", "401k", "ira ", "invest",
        "tax return", "taxes", "irs", "debt", "loan", "credit score", "bankrupt",
        "salary", "layoff", "laid off", "insurance claim", "deductible",
        "life insurance", "will and testament", "estate",
        // Legal
        "lawyer", "attorney", "lawsuit", "sue ", "custody", "divorce",
        "court date", "subpoena", "settlement", "contract review", "legal advice",
        // Security
        "password", "passcode", "social security", "ssn", "two-factor",
        "account was hacked", "identity theft", "fraud", "scam",
        // Loss and family difficulty
        "passed away", "funeral", "hospice", "obituary", "died", "death of",
        "miscarriage", "separation", "restraining order"
    ]

    /// Whether a memory category alone forces the sensitive gear.
    static func requiresSensitiveMode(categories: Set<MemoryCategory>) -> Bool {
        categories.contains(where: \.isSensitive)
    }
}
