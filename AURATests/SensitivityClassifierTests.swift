import Foundation
import Testing

@testable import AURA

@Suite("Sensitivity classifier")
struct SensitivityClassifierTests {

    private let classifier = SensitivityClassifier()

    @Test("Everyday requests stay in normal mode", arguments: [
        "What's on my schedule tomorrow?",
        "Add milk to my grocery list",
        "Remind me to order an air filter next week",
        "What did I decide about fantasy golf last week?",
        "Open Spotify",
        "What's my wife's favourite colour?",
        "Summarise everything I've told you about my current projects"
    ])
    func normalRequests(text: String) {
        #expect(classifier.classify(text) == .normal)
    }

    @Test("Health, money, legal and security topics become sensitive", arguments: [
        "What did the doctor say about my blood pressure?",
        "I need to refinance the mortgage",
        "My lawyer wants the contract review by Friday",
        "Remind me to change my password",
        "The biopsy results come back Thursday",
        "I'm meeting the attorney about custody",
        "My account was hacked",
        "Grandma's funeral is on Saturday"
    ])
    func sensitiveRequests(text: String) {
        #expect(classifier.classify(text) == .sensitive)
    }

    @Test("Signals of immediate danger become urgent", arguments: [
        "She's having chest pain, what do I do",
        "I can't breathe properly",
        "Should I call 911",
        "He collapsed in the kitchen"
    ])
    func urgentRequests(text: String) {
        #expect(classifier.classify(text) == .urgent)
    }

    @Test("Urgent outranks sensitive when both are present")
    func urgentWinsOverSensitive() {
        // Mentions medication (sensitive) and an overdose (urgent).
        #expect(classifier.classify("I think she took too much medication, possible overdose") == .urgent)
    }

    @Test("A retrieved health or finance memory makes an innocuous question sensitive")
    func retrievedCategoryEscalates() {
        let text = "What did they say again?"
        #expect(classifier.classify(text) == .normal)
        #expect(classifier.classify(text: text, retrievedCategories: [.health]) == .sensitive)
        #expect(classifier.classify(text: text, retrievedCategories: [.finance]) == .sensitive)
        #expect(classifier.classify(text: text, retrievedCategories: [.sports]) == .normal)
    }

    @Test("Urgent text is not downgraded by benign retrieved categories")
    func urgentSurvivesRetrieval() {
        #expect(
            classifier.classify(text: "chest pain right now", retrievedCategories: [.sports]) == .urgent
        )
    }

    @Test("Only health and finance categories force sensitive mode")
    func onlyExpectedCategoriesAreSensitive() {
        let sensitive = MemoryCategory.allCases.filter(\.isSensitive)
        #expect(Set(sensitive) == Set([.health, .finance]))
    }

    @Test("Classification ignores case and surrounding whitespace")
    func normalisesInput() {
        #expect(classifier.classify("   MY MORTGAGE payment  ") == .sensitive)
    }

    @Test("Sensitive and urgent modes carry guidance; normal does not")
    func instructionsExistWhereNeeded() {
        #expect(SensitivityMode.normal.instruction == nil)
        #expect(SensitivityMode.sensitive.instruction != nil)
        #expect(SensitivityMode.urgent.instruction != nil)
    }
}
