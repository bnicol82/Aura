import Foundation

/// Looks someone up in the address book (§37).
///
/// ### Why reachable details are opt-in
/// This is the one system tool where the read itself is the privacy decision. "Who is Priya?" needs a name
/// and a relationship; handing the model every phone number and email attached to that contact is more of
/// the user's address book than the question called for, and §28 says a request gets what it needs and no
/// more. So the numbers are behind a parameter the model has to choose, and the tool's description tells it
/// when choosing that is appropriate.
struct LookUpContactTool: AssistantTool {

    let id = "contacts.lookup"
    let name = "look_up_contact"

    var description: String {
        """
        Find someone in the user's contacts by name. Use it to work out who a person the user mentioned is, \
        or how they are related. Set include_contact_details only when the user actually asked for a way to \
        reach someone — otherwise leave it off, because their phone numbers are not needed to know who they \
        are.
        """
    }

    var parameters: ToolParameterSchema {
        ToolParameterSchema([
            ToolParameter(
                name: "name",
                description: "The name or part of a name to search for.",
                type: .string,
                isRequired: true
            ),
            ToolParameter(
                name: "include_contact_details",
                description: """
                    True to also return phone numbers and email addresses. Only set this when the user \
                    asked how to contact someone.
                    """,
                type: .boolean,
                isRequired: false
            )
        ])
    }

    let riskLevel: ToolRiskLevel = .readOnly
    var requiredPermissions: Set<AuraPermission> { [.contacts] }

    /// How many matches one lookup returns.
    ///
    /// Small on purpose. A search for "John" in a big address book would otherwise put a dozen people into
    /// the prompt, and the model needs to know it should ask which one rather than pick.
    static let resultLimit = 5

    private let contactService: any ContactLookupServicing

    init(contactService: any ContactLookupServicing) {
        self.contactService = contactService
    }

    func progressLabel(for arguments: ToolArguments) -> String {
        "Looking up a contact"
    }

    func execute(arguments: ToolArguments, context: ToolExecutionContext) async throws -> ToolResult {
        let name = try arguments.string("name")
        let includeDetails = arguments.optionalBool("include_contact_details") ?? false

        let matches = try await contactService.contacts(
            matchingName: name,
            includingReachableDetails: includeDetails,
            limit: Self.resultLimit
        )

        guard !matches.isEmpty else {
            return ToolResult(
                // Names the possibility that access is partial, because iOS 18 lets the user share a
                // subset — and "no such person" would be wrong in that case, not just unhelpful.
                modelFacingText: """
                    No contact matches “\(name)”. Either they are not in the user's contacts, or the user \
                    only shared some of their contacts with AURA. Do not guess who they are.
                    """,
                activityLabel: "Looked up a contact",
                outcomeSummary: "No match for “\(name)”",
                didMutateData: false
            )
        }

        return ToolResult(
            modelFacingText: Self.render(matches, query: name, includedDetails: includeDetails),
            activityLabel: "Looked up a contact",
            outcomeSummary: matches.count == 1 ? matches[0].displayName : "\(matches.count) matches",
            didMutateData: false
        )
    }

    // MARK: - Pure rendering

    /// Formats matches for the model.
    ///
    /// `static` and pure so the wording is pinned by a test. Two things it must do: say when there is more
    /// than one match, so the model asks rather than picking; and say when details were not fetched, so it
    /// does not conclude the contact has no number.
    static func render(
        _ contacts: [ContactSnapshot],
        query: String,
        includedDetails: Bool
    ) -> String {
        let lines = contacts.map { contact -> String in
            var parts = [contact.displayName]
            if let nickname = contact.nickname, nickname != contact.displayName {
                parts.append("known as \(nickname)")
            }
            if !contact.relations.isEmpty {
                parts.append("relationship: \(contact.relations.joined(separator: ", "))")
            }
            if let organization = contact.organizationName {
                parts.append("at \(organization)")
            }
            if includedDetails {
                if !contact.phoneNumbers.isEmpty {
                    parts.append("phone: \(contact.phoneNumbers.joined(separator: ", "))")
                }
                if !contact.emailAddresses.isEmpty {
                    parts.append("email: \(contact.emailAddresses.joined(separator: ", "))")
                }
                if contact.phoneNumbers.isEmpty && contact.emailAddresses.isEmpty {
                    parts.append("no phone or email saved")
                }
            }
            return "- " + parts.joined(separator: "; ")
        }

        var text: String
        if contacts.count == 1 {
            text = "One contact matches “\(query)”:\n\(lines[0])"
        } else {
            text = """
                \(contacts.count) contacts match “\(query)”. Ask the user which one they meant rather than \
                choosing:
                \(lines.joined(separator: "\n"))
                """
        }

        if !includedDetails {
            // Without this the model can read the absence of a number as the absence of a number *saved*,
            // and tell the user they have no way to reach someone they do (§78).
            text += "\n(Phone numbers and emails were not looked up, so nothing here says whether any exist.)"
        }
        return text
    }
}
