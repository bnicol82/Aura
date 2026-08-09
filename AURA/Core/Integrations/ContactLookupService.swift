import Contacts
import Foundation

/// One person from the address book, as everything above Contacts sees it.
///
/// ### Why the reachable details are separated from the identity
/// "Who is Priya?" needs a name and a relationship. "What's Priya's number?" needs the number. Those are
/// very different amounts of the user's address book to put into a model prompt, and §28 says a request
/// gets only what it needs. So phone numbers and emails are a separate, opt-in part of the snapshot rather
/// than something every lookup carries.
struct ContactSnapshot: Sendable, Equatable, Identifiable, Hashable {
    var id: String
    /// The formatted full name, or the nickname when there is no name at all.
    var displayName: String
    var organizationName: String?
    var nickname: String?
    /// Relationship labels the user has set — "sister", "manager". Genuinely useful for grounding.
    var relations: [String]
    /// Empty unless the caller asked for reachable details.
    var phoneNumbers: [String]
    /// Empty unless the caller asked for reachable details.
    var emailAddresses: [String]
    /// `true` when the contact has a number or address AURA did not fetch, so a tool can say "she has a
    /// number saved" without handing it over.
    var hasReachableDetails: Bool

    init(
        id: String,
        displayName: String,
        organizationName: String? = nil,
        nickname: String? = nil,
        relations: [String] = [],
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        hasReachableDetails: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.organizationName = organizationName
        self.nickname = nickname
        self.relations = relations
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.hasReachableDetails = hasReachableDetails
    }
}

/// Looking someone up in the address book (§37).
protocol ContactLookupServicing: Sendable {
    /// Contacts whose name matches `name`.
    ///
    /// - Parameter includingReachableDetails: when `false`, phone numbers and emails are left out of the
    ///   result entirely rather than fetched and discarded — the fetch itself is what §28 is about.
    func contacts(
        matchingName name: String,
        includingReachableDetails: Bool,
        limit: Int
    ) async throws -> [ContactSnapshot]
}

/// `ContactLookupServicing` over the Contacts framework.
///
/// ### APIs verified against Apple's documentation before use
/// | API | Verified shape |
/// |---|---|
/// | `CNContactStore.authorizationStatus(for:)` | `class func`, returns `CNAuthorizationStatus` |
/// | `CNAuthorizationStatus` | includes `.limited` as well as `.authorized` |
/// | `CNContact.predicateForContacts(matchingName:)` | `class func`, returns `NSPredicate` |
/// | `unifiedContacts(matching:keysToFetch:)` | `throws`, `keys: [any CNKeyDescriptor]` |
/// | `CNContactFormatter.descriptorForRequiredKeys(for:)` | returns `any CNKeyDescriptor` |
/// | `CNContactFormatter.string(from:style:)` | `class func`, returns `String?` |
/// | `CNContact.phoneNumbers` | `[CNLabeledValue<CNPhoneNumber>]`, value has `stringValue` |
actor SystemContactLookupService: ContactLookupServicing {

    private let store: CNContactStore

    init(store: CNContactStore = CNContactStore()) {
        self.store = store
    }

    func contacts(
        matchingName name: String,
        includingReachableDetails: Bool,
        limit: Int
    ) async throws -> [ContactSnapshot] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized, .limited:
            break
        case .denied, .restricted, .notDetermined:
            throw AuraError.permissionDenied(.contacts)
        @unknown default:
            throw AuraError.permissionDenied(.contacts)
        }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let predicate = CNContact.predicateForContacts(matchingName: trimmed)
        let matched: [CNContact]
        do {
            matched = try store.unifiedContacts(
                matching: predicate,
                keysToFetch: Self.keys(includingReachableDetails: includingReachableDetails)
            )
        } catch {
            throw AuraError.toolFailed(toolName: "look_up_contact", reason: error.localizedDescription)
        }

        return matched.prefix(max(1, limit)).map {
            Self.snapshot(from: $0, includingReachableDetails: includingReachableDetails)
        }
    }

    // MARK: - Pure helpers

    /// The keys to fetch.
    ///
    /// `static` and pure so the §28 decision — which parts of a contact leave the address book at all — is
    /// one readable list with a test, rather than an argument assembled at a call site. Numbers and emails
    /// are genuinely not requested when they were not asked for; fetching and then discarding them would
    /// keep the promise in the wording only.
    static func keys(includingReachableDetails: Bool) -> [any CNKeyDescriptor] {
        var keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactRelationsKey as CNKeyDescriptor
        ]
        if includingReachableDetails {
            keys.append(CNContactPhoneNumbersKey as CNKeyDescriptor)
            keys.append(CNContactEmailAddressesKey as CNKeyDescriptor)
        }
        return keys
    }

    private static func snapshot(
        from contact: CNContact,
        includingReachableDetails: Bool
    ) -> ContactSnapshot {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)
        let nickname = contact.isKeyAvailable(CNContactNicknameKey) ? contact.nickname : ""
        let organization = contact.isKeyAvailable(CNContactOrganizationNameKey)
            ? contact.organizationName
            : ""

        // Every accessor is guarded by `isKeyAvailable`. Reading an unfetched key on a `CNContact` raises
        // an Objective-C exception, which cannot be caught — so a key that was deliberately not requested
        // must never be read, and "not requested" is exactly the case this whole type is built around.
        let phones: [String] = includingReachableDetails && contact.isKeyAvailable(CNContactPhoneNumbersKey)
            ? contact.phoneNumbers.map(\.value.stringValue)
            : []
        let emails: [String] = includingReachableDetails
            && contact.isKeyAvailable(CNContactEmailAddressesKey)
            ? contact.emailAddresses.map { $0.value as String }
            : []

        let relations: [String] = contact.isKeyAvailable(CNContactRelationsKey)
            ? contact.contactRelations.compactMap { relation in
                guard let label = relation.label else { return nil }
                return CNLabeledValue<CNContactRelation>.localizedString(forLabel: label)
            }
            : []

        return ContactSnapshot(
            id: contact.identifier,
            displayName: Self.displayName(formatted: formatted, nickname: nickname, organization: organization),
            organizationName: organization.isBlank ? nil : organization,
            nickname: nickname.isBlank ? nil : nickname,
            relations: relations,
            phoneNumbers: phones,
            emailAddresses: emails,
            // Only meaningful when the details were fetched; otherwise AURA genuinely does not know, and
            // claiming either way would be a guess.
            hasReachableDetails: !phones.isEmpty || !emails.isEmpty
        )
    }

    /// A name to call this contact, given whatever the address book actually has.
    ///
    /// A contact with no name is real — a saved number, a company entry — and rendering it as an empty
    /// string would have the model referring to "" as a person. Falls through name, nickname, organisation,
    /// and finally says outright that there is no name.
    static func displayName(formatted: String?, nickname: String, organization: String) -> String {
        if let formatted, !formatted.isBlank { return formatted }
        if !nickname.isBlank { return nickname }
        if !organization.isBlank { return organization }
        return "an unnamed contact"
    }
}

/// A fixed address book, for tests and previews.
struct StubContactLookupService: ContactLookupServicing {
    var results: [ContactSnapshot] = []
    var failure: AuraError?

    func contacts(
        matchingName name: String,
        includingReachableDetails: Bool,
        limit: Int
    ) async throws -> [ContactSnapshot] {
        if let failure { throw failure }
        let matched = results.filter {
            $0.displayName.localizedCaseInsensitiveContains(name)
                || ($0.nickname?.localizedCaseInsensitiveContains(name) ?? false)
        }
        // Mirrors the real service: details are absent unless asked for, so a test cannot pass by
        // accident against a stub that always returns them.
        return matched.prefix(max(1, limit)).map { contact in
            guard includingReachableDetails else {
                var stripped = contact
                stripped.phoneNumbers = []
                stripped.emailAddresses = []
                return stripped
            }
            return contact
        }
    }
}
