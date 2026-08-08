# AURA — Architecture

The reference for how AURA is put together and why. Section numbers in parentheses (§27, §34) refer to
the master specification.

---

## 1. Recommended architecture

A single-module SwiftUI application with a layered core, protocol boundaries at every seam that needs
to be swapped or tested, and value types crossing every concurrency boundary.

```
                        ┌──────────────────────────┐
   Voice / Text  ─────► │  AssistantOrchestrator   │ ◄──── App Intents, Siri,
                        │  (the only turn writer)  │       Shortcuts, Widgets
                        └────────────┬─────────────┘
                                     │
        ┌────────────────────────────┼────────────────────────────┐
        ▼                            ▼                            ▼
┌───────────────┐          ┌──────────────────┐        ┌────────────────────┐
│ Personalization│         │   ModelRouter    │        │   ToolExecutor     │
│    Engine     │          │                  │        │ permissions +      │
│ ─ personality │          │ ─ on-device      │        │ confirmation gate  │
│ ─ retrieval   │          │ ─ cloud (opt-in) │        │ ─ audit trail      │
└───────┬───────┘          └────────┬─────────┘        └─────────┬──────────┘
        │                           │                            │
        ▼                           ▼                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│  Stores — actors over one SwiftData ModelContainer                        │
│  AssistantProfile · UserProfile · Memory · Conversation · Activity        │
└───────────────────────────────┬───────────────────────────────────────────┘
                                ▼
              SQLite on device  ──►  CloudKit private database (Phase 9)
```

Three rules hold the design together. Each one is load-bearing, not stylistic.

**One writer per turn.** `AssistantOrchestrator` is the only thing that assembles a prompt, calls a
model, runs a tool, or saves a message. Views never do any of it. This is what keeps the context
discipline of §28 and the honesty rules of §78 in one auditable path rather than scattered across the
UI, where they would drift apart within a few features.

**Snapshots cross every boundary.** SwiftData's `PersistentModel` is not `Sendable`. Every store is a
`@ModelActor` actor, and everything entering or leaving it is a `Sendable` struct — `MemorySnapshot`,
`AssistantProfileSnapshot`, `PersonProfileSnapshot`. Passing model objects between isolation domains is
the most common way to corrupt a SwiftData app under Swift 6, and the type system prevents it here.
Views may still use `@Query` directly for browsing, which runs on the main actor against the same
container.

**Retrieval is the privacy boundary.** `MemoryRetrieving` is the only thing that decides what a model
learns about the user. Providers are forbidden from touching the profile or memory stores; they receive
a finished `ModelRequest` and nothing else. That is what makes "AURA never sends your whole memory to a
third party" a property you can verify by reading one type instead of auditing the whole app.

---

## 2. Recommended deployment target

**iOS 26.0.**

| Requirement | Available from |
|---|---|
| `FoundationModels` — `SystemLanguageModel`, `LanguageModelSession`, `Tool` | iOS 26.0 |
| `Speech` — `SpeechAnalyzer`, `SpeechTranscriber` | iOS 26.0 |
| SwiftData `@ModelActor`, `VersionedSchema` | iOS 17.0 |
| Swift 6 strict concurrency | Xcode 16+ |

iOS 26 is what Apple's on-device model requires, and the specification asks for it (§5). No earlier
target buys anything, since the whole intelligence layer would be unavailable.

Apple Intelligence eligibility is a *separate* axis from OS version and is handled at runtime, not by
the deployment target. On an iOS 26 device without it, memory, profiles, search, conversation history
and the entire UI work; language-model replies need either eligible hardware or a configured cloud
provider (§68).

---

## 3. Apple frameworks

| Framework | Used for | Phase |
|---|---|---|
| SwiftUI | The whole interface | 1 |
| SwiftData | Persistence, schema, migrations | 1 |
| Foundation, OSLog | Values, dates, logging | 1 |
| Security | Keychain credential storage | 1 |
| FoundationModels | On-device inference, structured output, tools | 2 |
| Speech, AVFoundation | Transcription and synthesis | 5 |
| CloudKit (via SwiftData mirroring) | Private sync | 9 |
| AppIntents | Siri, Shortcuts, Action Button | 11 |
| EventKit, WeatherKit, Contacts, CoreLocation, UserNotifications | Productivity tools | 12 |
| NaturalLanguage | Entity recognition during extraction | 7 |
| WidgetKit, CoreSpotlight | Widgets, system search | 11–12 |

No third-party dependencies, and none planned.

---

## 4. Project structure

```
AURA/
  App/               AuraApp, AppEnvironment (DI container), RootView, MainTabView
  Core/
    AI/
      Providers/      LanguageModelProvider, ModelAvailability, MockLanguageModelProvider
      Routing/        ModelRouting, ModelRoute, RoutingContext
      Orchestration/  AssistantRequest/Response, AssistantTurnEvent, AssistantOrchestrating
    Personalization/
      PersonalityEngine, SensitivityClassifier, PersonalizationEngine
      AssistantProfile/  AssistantProfileStore
      UserProfile/       UserProfileStore
    Memory/
      Storage/        MemoryStoring, MemoryDraft, MemoryQuery
      Retrieval/      MemoryRetrieving, RankedMemory, MemoryRelevanceScore
      Extraction/     MemoryExtracting, MemoryImportanceScoring, MemoryConsolidating
      EmbeddingProvider
    Tools/            AssistantTool, ToolRegistry, ToolExecuting, ToolRiskLevel
    Voice/            SpeechRecognitionService, SpeechSynthesisService, VoiceState
    Conversation/     ConversationStoring
    Activity/         ActivityLogging
    Storage/          PersistenceController, AuraSchema, SyncConfiguration
    Security/         SecureCredentialStore
    Permissions/      AuraPermission, PermissionManaging
    Support/          AuraLog, AuraError, JSONValue, AuraDefaults, TextTokenization, FeatureStage
  Models/             SwiftData models + their Sendable snapshots
  Features/           Assistant, Memory, Activity, Settings, Onboarding, Shared
  Resources/          Assets.xcassets
AURATests/            Swift Testing suites
```

A model and its snapshot live in the same file. They change together — adding a field means touching
both — and splitting them just guarantees one gets forgotten.

---

## 5. Core protocols

| Protocol | Responsibility | Why it is a protocol |
|---|---|---|
| `LanguageModelProvider` | One model, one API | Apple / Claude / OpenAI / mock are interchangeable |
| `ModelRouting` | Which model answers | Routing policy is testable without any model |
| `AssistantOrchestrating` | The turn pipeline | A full turn runs against mocks, no device needed |
| `PersonalizationEngineProtocol` | Assemble the context | Context assembly asserted directly in tests |
| `AssistantProfileStoring` / `UserProfileStoring` | Identity and knowledge | Fakes for UI tests |
| `MemoryStoring` / `MemoryRetrieving` / `MemoryExtracting` / `MemoryConsolidating` | The memory system | Four separable problems, separately testable |
| `MemoryImportanceScoring` | What deserves keeping | Pure function; the most test-worthy piece in the app |
| `EmbeddingProvider` | Vectors | V1 has none; V2 adds one without touching ranking |
| `AssistantTool` / `ToolExecuting` / `ToolConfirmationRequesting` | Actions | Safety tiers tested without side effects |
| `ConversationStoring` | Transcript archive | |
| `SpeechRecognitionService` / `SpeechSynthesisService` | Voice | Voice flows tested with no microphone |
| `PermissionManaging` | Authorizations | Denial paths tested without system prompts |
| `SecureCredentialStoring` | Secrets | Keychain is flaky in tests |
| `ActivityLogging` | Audit trail | |

`PersonalityEngine`, `SensitivityClassifier` and `PersonalityEngine.stylePreview` are deliberately
**not** protocols. They are pure value types with no dependencies; abstracting them would add a seam
with nothing on the other side of it.

### The tool-execution split

Worth calling out, because it is forced by the platform rather than invented:

- Apple's `FoundationModels.Tool` is invoked **by the framework**, inside `LanguageModelSession`. The
  session calls `Tool.call(arguments:)` itself and never returns control to us mid-generation.
- Cloud APIs do the reverse: they return a tool-call request and wait for the caller to run it.

So `LanguageModelProvider` declares a `toolExecutionStyle`, and provider-managed providers are handed a
`ToolInvoking` reference. `ToolExecutor` is the only implementation of it, which means a
framework-initiated tool call is subject to the same permission checks, confirmation gates and audit
logging as an orchestrator-initiated one. A provider cannot route around §34.

---

## 6. Data models

Fifteen `@Model` types, all in `AuraSchemaV1`:

| Model | Holds |
|---|---|
| `AssistantProfile` | Name, personality, style, voice, AI mode, memory policy — one row |
| `UserProfile` | Preferred name, context, lists, standing instructions — one row |
| `ProfileFact` | One categorised fact: label, value, confidence, provenance |
| `PersonProfile` | Someone who matters, with aliases and search text |
| `ImportantDate` | Birthdays, anniversaries, renewals, deadlines |
| `Conversation` / `Message` | Transcript, tool activity, provider attribution |
| `MemoryItem` | A memory with importance, confidence, links, supersession, expiry |
| `MemoryCandidate` | A proposal awaiting review or record of one |
| `Project` / `AssistantTask` | Ongoing efforts and outstanding obligations |
| `ToolExecution` | What ran, whether it succeeded, whether it was confirmed |
| `ActivityRecord` | The user-facing audit line |
| `KnowledgeDocument` | Imported files — intentional stub, empty in V1 |
| `UserPreference` | Loose device-local key/value settings |

### Why `ProfileFact` instead of twenty-four columns

The specification lists many preference buckets on `UserProfile` — food, travel, sports,
entertainment, shopping, technology, favourite things. Modelling each as its own array would freeze the
schema around today's guesses and give retrieval two dozen places to look. Instead they are
`ProfileFact` rows carrying a `MemoryCategory`, which means a new bucket is a new enum case rather than
a store migration, every fact gets confidence and provenance and pinning for free, and retrieval
filters one relationship instead of unioning many arrays. Genuinely singular fields — the user's name,
their standing instructions — stay as columns, because there is exactly one of each.

### Conventions every model follows

1. **Enums are raw `String` columns** with computed typed accessors. `#Predicate` cannot see through a
   computed property, and CloudKit stores `Codable` enums as opaque binary — raw columns keep both
   querying and mirroring working.
2. **Cross-entity references are `UUID` arrays, not relationships,** where a relationship would create
   a dense or cyclic graph (memory → person, memory → project, task → memory). Relationships are
   reserved for genuine ownership: conversation → messages, person → dates, project → tasks.
3. **A `searchText` column** on anything searchable, holding a flat lower-cased haystack, because
   `#Predicate` cannot look inside `[String]`.
4. **`snapshot`** on every model, producing the `Sendable` value type.

---

## 7. CloudKit strategy

Local-first, always. SQLite on device is the working copy; CloudKit mirrors it through the user's
**private** database. No model ever executes in iCloud (§8).

The schema is written to satisfy SwiftData's mirroring constraints from day one, whether or not sync is
switched on:

1. Every attribute has a default value or is optional.
2. No `@Attribute(.unique)` and no `#Unique`. Singleton rows — `AssistantProfile`, `UserProfile` — are
   enforced by their store actor instead.
3. Every relationship is optional with an explicit inverse: `[Message]?`, not `[Message]`.
4. No `.deny` delete rules.

**Conflicts.** Last-writer-wins on a field basis is what SwiftData mirroring gives us. Two cases need
more than that and get it:

- *Duplicate singletons.* Two devices completing onboarding offline each create a profile row, and both
  sync. `resolveSingleton()` reconciles deterministically — most recently updated wins, ties break by
  creation date then by UUID — and, for `UserProfile`, re-parents the loser's facts and people onto the
  winner before deleting it. Dropping a duplicate must not drop what it held.
- *Corrected memories.* Corrections supersede rather than overwrite (§23), so two devices correcting
  the same fact converge on two memories with one marked superseded, rather than on a lost update.

**Why sync is off in Phase 1.** An iCloud container that does not exist in the developer's account
makes the app fail to provision, so a fresh checkout would not build. `SyncConfiguration.default` is
`.localOnly`, the entitlements ship as a template, and Phase 9 flips both.

---

## 8. Memory architecture

Six layers (§15), mapped onto storage:

| Layer | Where it lives |
|---|---|
| Working memory | `Conversation.workingMemory(limit:)` — the last N visible turns |
| Semantic | `MemoryItem` (`.semantic`) and `ProfileFact` |
| Episodic | `MemoryItem` (`.episodic`) |
| Project | `MemoryItem` (`.project`) + `Project` |
| Task | `AssistantTask` |
| Archive | `Conversation` / `Message` in full |

### The pipeline

```
turn ──► MemoryExtracting ──► MemoryCandidate ──► MemoryImportanceScoring
                                                          │
                        ┌─────────────────────────────────┤
                        ▼                                 ▼
              ≥ 0.85 durable memory              0.60–0.84 episodic
              + profile promotion                          │
                        │                                  ▼
                        └────► MemoryConsolidating    < 0.60 archive only
```

Extraction runs **on-device only**, always, whatever AI mode the user chose. It sees raw user speech
before any relevance judgement has been made, so routing it to a third party would leak precisely what
§50 protects. `ModelRequestPurpose.isOnDeviceOnly` enforces this above the user's own "prefer the best
model" setting — that setting is not permission to leak.

### Correction and forgetting

Correction writes a new memory and marks the old one `supersededByMemoryID`. Only *current* memories —
not superseded, not archived, not expired — are eligible for retrieval, so a corrected fact can never
resurface as current while the audit trail survives. `ProfileFact` uses the same shape via
`supersededByFactID`.

Forgetting (§24) is a genuine delete. Someone who asks AURA to forget something must not find it still
in the store. `ForgetOutcome` returns counts so AURA reports what it actually removed rather than
assuming (§78).

### Retrieval

Eight weighted terms (§30), kept as a struct rather than collapsed to one number so the UI can explain
*why* something was recalled and tests can assert on individual terms:

| Term | Weight | V1 |
|---|---|---|
| Semantic similarity | 3.00 | always 0 — no embeddings |
| Keyword overlap | 2.50 | active |
| Entity match | 2.00 | active |
| Contextual link | 1.75 | active |
| Importance | 1.50 | active |
| Pinned | 1.25 | active |
| Recency | 1.00 | active |
| Usage | 0.50 | active |

Semantic similarity is weighted and wired but always zero, because V1 must not depend on embeddings
(§31). `MemoryItem.embeddingReference` exists so V2 backfills vectors without a migration.

---

## 9. Personalization architecture

```
AssistantProfile ─┐
UserProfile ──────┼──► PersonalizationEngine ──► PersonalizationContext ──► ModelRequest.instructions
Retrieval ────────┘            ▲
                               │
                    PersonalityEngine (pure)
                    SensitivityClassifier (pure)
```

`PersonalityEngine` is the **only** place personality prompt text is written (§11). Nothing else may
append "be concise" to a prompt — duplicated personality logic drifts, and the assistant stops feeling
like one character.

`SensitivityClassifier` runs on-device with no dependencies, before any model call. Asking a model
"is this sensitive?" would cost a round trip per turn and, worse, would let a network failure leave
humour switched on during a conversation about someone's diagnosis. It errs toward seriousness: a false
positive costs one flat answer, a false negative costs a joke about a biopsy.

Honesty rules are appended to every request regardless of personality, because they are not stylistic.
`PersonalityEngineTests` asserts this across every preset × sensitivity combination.

Context priority (§29) is resolved in `PersonalizationContext.modelInstructions()`: current message,
then current conversation, then standing instructions, then assistant settings, then profile, people,
projects, memories. When nothing relevant exists the model is told so explicitly, rather than left to
fill the silence with plausible invention.

---

## 10. Voice architecture

One `VoiceState` enum drives the orb, the microphone button, accessibility announcements and input
acceptance. A single state machine rather than several booleans is what prevents the impossible
combinations — listening while speaking, thinking with nothing pending — that make voice UIs feel
broken.

```
idle ──► listening(transcript) ──► processing ──► [toolExecution(label)] ──► speaking ──► idle
                                                        │
                                                        └──► error(AuraError)
```

Recognition uses iOS 26's `SpeechAnalyzer` + `SpeechTranscriber`. Two facts about that API shape the
protocol: transcription can be unsupported for the user's language even on eligible hardware, so
`availability()` is async and returns a reason rather than a bool; and assets may need downloading,
which is a visible wait, so `prepare()` is a separate step from `startListening()`.

Raw microphone audio is never persisted (§38). Synthesis never imitates a real person's voice (§39) —
that is permanent, not an implementation detail.

---

## 11. Tool architecture

```
model wants a tool
      │
      ▼
ToolRegistry.availableTools(for: criteria)   ← permissions, connectivity, risk ceiling
      │
      ▼
ToolExecutor
  1. resolve by name        → unknown name is an error, never a silent no-op
  2. check permission       → request contextually if undetermined
  3. gate on confirmation   → by tier and by who initiated it
  4. execute with timeout
  5. record ToolExecution + ActivityRecord — success or failure, always
      │
      ▼
ToolResult ──► modelFacingText (grounds the reply)
          └──► activityLabel + outcomeSummary (what the user sees)
```

Tools that cannot run are **withheld, not offered and then failed**. Offering a tool whose permission
was denied invites the model to promise something AURA cannot deliver.

| Tier | Confirmation |
|---|---|
| `readOnly` | Never, once the permission exists |
| `reversible` | Only when the model volunteered it, not when the user asked |
| `consequential` | Always, immediately before execution |

An unattended entry point — a widget, a Shortcut — gets `AvailabilityCriteria.unattended`: read-only
only. `DecliningConfirmationRequester` returns `false` for everything, because silence is never consent.

§78 is enforced structurally, not by prompt: the model never reports outcomes. `ToolExecutor` does,
from a returned `ToolResult` or a thrown error.

---

## 12. Security and privacy architecture

| Concern | Approach |
|---|---|
| Secrets | Keychain via `KeychainCredentialStore`, `afterFirstUnlockThisDeviceOnly`. Never in SwiftData or CloudKit. |
| API keys | User-entered supported for development, as §51 allows, and labelled as such. Production shape is a backend-minted token — hence `CredentialKey.auraBackendToken`. |
| Logging | `OSLog` carries shapes only: counts, ids, durations, error kinds. Never user content, memory text, transcripts or prompts. |
| Audit trail | `ActivityRecord` deliberately *does* carry personal content — it is for the user. It has no field for reasoning, and never will. |
| Cloud egress | Only `PersonalizationContext` contents reach a provider. `personalItemCount` makes the amount visible in the dashboard. |
| On-device pinning | Extraction and classification never leave the device, regardless of AI mode. |
| Deletion | `deleteAllProfileData`, `deleteAllMemories`, `deleteAllConversations`, `credentialStore.deleteAll()` — real deletes, reachable from Settings, confirmed before running. |
| Permissions | Requested contextually, one at a time. A denial disables exactly one capability and says which. |

Two things AURA structurally cannot do: send memory a request did not need (there is no path from a
provider to a store), and claim an action it did not take (there is no path from a model's text to an
`ActivityRecord`).

---

## 13. App Intent architecture (Phase 11)

Planned intents: `AskAURAIntent`, `StartConversationIntent`, `RememberThisIntent`,
`SearchMemoryIntent`, `AddQuickNoteIntent`, `SummarizeTodayIntent`, `OpenAssistantIntent`.

Every one is a thin shell over `AssistantOrchestrating` with an `AssistantRequestSource`. The source is
not cosmetic — `isInteractive` decides whether tools above `readOnly` are even offered, since a Shortcut
cannot show a confirmation sheet.

The Action Button flow (§40) is `OpenAssistantIntent` → app foregrounds → `VoiceState.listening`
immediately, with no intermediate tap.

`AppShortcutsProvider` phrases use the assistant's chosen name where App Intents permits it. Apple
resolves shortcut phrases at build time from a static `AppShortcut` list, so a fully dynamic name is not
possible; the plan is `${applicationName}` plus a `.systemImageName`, with the in-app title and spoken
responses using the chosen name everywhere they can.

---

## 14. MVP roadmap

| Phase | Delivers | State |
|---|---|---|
| 1 | Architecture, schema, protocols, profile stores, personality engine, UI shell, onboarding | **Done** |
| 2 | `AppleFoundationModelProvider`, `ModelRouter`, working text conversation | Next |
| 3 | `AssistantOrchestrator`, context assembly, streaming | |
| 4 | Personality wired end to end | Engine done in 1 |
| 5 | Speech recognition and synthesis, voice state machine | |
| 6 | Conversation persistence | |
| 7 | Extraction, importance scoring, correction, forgetting, retrieval | |
| 8 | Memory UI over real memories | Profile UI done in 1 |
| 9 | CloudKit sync and conflict handling | |
| 10 | Tool registry, executor, memory tools, confirmations | |
| 11 | App Intents, Shortcuts, Action Button | |
| 12 | Calendar, Reminders, Weather, Contacts, Location | |
| 13 | Privacy hardening, security review, performance | |

Phases 4 and 8 are partly delivered early because both were needed to make Phase 1's onboarding and
profile editing genuinely work rather than mock them.

---

## Appendix: verified API surface

Checked against Apple's live documentation while writing Phase 1, since inventing an API is worse than
not using one.

| Symbol | Introduced | Notes |
|---|---|---|
| `SystemLanguageModel.availability` → `.available` / `.unavailable(.deviceNotEligible / .appleIntelligenceNotEnabled / .modelNotReady)` | iOS 26.0 | mapped onto `ModelAvailability` |
| `LanguageModelSession.respond(to:options:)`, `.streamResponse(to:)` | iOS 26.0 | stream yields **cumulative** `Snapshot`s, so `AppleFoundationModelProvider` must diff to produce deltas |
| `FoundationModels.Tool` — `Arguments: ConvertibleFromGeneratedContent`, `parameters: GenerationSchema` | iOS 26.0 | framework-executed; drives `ToolExecutionStyle` |
| `LanguageModelSession.GenerationError` | iOS 26.0 | **deprecated in the iOS 27 beta SDK**, partly replaced by `LanguageModelSession.Error`; expect deprecation warnings under a newer SDK |
| `SpeechAnalyzer` (actor), `SpeechTranscriber.isAvailable` / `installedLocales` / `results` | iOS 26.0 | supersedes `SFSpeechRecognizer` |
| `ModelConfiguration(_:schema:isStoredInMemoryOnly:allowsSave:groupContainer:cloudKitDatabase:)` | iOS 17.0 | `.none` in Phase 1, `.private(_:)` in Phase 9 |
