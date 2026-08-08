# Build log

One entry per implementation stage, in the format of §77: status, files, what works, tests, known
limitations, compile risks, next step.

---

## Phase 2 — Basic Intelligence

**Status: complete, not yet compiled.**

AURA holds a real conversation as of this stage. Typed input goes to Apple's on-device model through the
orchestrator, the answer is persisted, and the transcript renders from the store.

### Files created (7)

`Core/AI/Providers/AppleFoundationModelProvider.swift` ·
`Core/AI/Routing/DefaultModelRouter.swift` ·
`Core/AI/Orchestration/AssistantOrchestrator.swift` ·
`Core/Conversation/SwiftDataConversationStore.swift` ·
`Core/Personalization/DefaultPersonalizationEngine.swift` ·
`Core/Support/NetworkMonitor.swift` ·
`Features/Assistant/ConversationController.swift`

**Tests (4)** — `ModelRouterTests.swift` · `AssistantOrchestratorTests.swift` ·
`ConversationStoreTests.swift` · `AppleProviderTests.swift`

### Files modified (8)

`App/AppEnvironment.swift` — wires the intelligence layer and exposes live provider states ·
`Core/Support/FeatureStage.swift` — `textConversation` and `conversationHistory` flipped to `.live` ·
`Features/Assistant/ConversationView.swift` — working composer, store-backed transcript ·
`Features/Assistant/AssistantHomeView.swift` — model-availability notice replaces the pending note ·
`Features/Settings/AIModelSettingsView.swift` — real provider rows ·
`Features/Settings/PrivacyDashboardView.swift` — on-device status from a live check, not a build flag ·
`Features/Onboarding/OnboardingSteps.swift` — final screen no longer disclaims typing ·
`Features/Shared/PendingFeatureNotice.swift` — preview points at a still-pending stage

### Features now working

- **Typed conversation.** Send a message, get an answer from `SystemLanguageModel`, see it persist.
- **Multi-turn continuity.** History is rendered into each prompt, bounded by
  `AuraDefaults.workingMemoryTurnLimit`, and a conversation resumes for six hours before a new one starts.
- **Model routing.** All three AI modes, on-device preference, cloud fallback with the reason attached,
  and escalation after a context-window overflow.
- **On-device pinning.** Extraction and classification cannot leave the device, including in
  cloud-enhanced mode. Enforced in `DefaultModelRouter` and asserted across every mode.
- **Selective context.** A question about Blake retrieves Blake and not Jennifer, using
  `UserProfileStore`'s keyword search — real selectivity from the first conversation, not deferred to
  Phase 7.
- **Sensitivity in the loop.** Topic classification runs per turn and reaches the model's instructions.
- **Honest failures.** Every failure writes a flagged message; `workingMemory` excludes them so the model
  never treats an error as its own prior answer. A user-cancelled turn writes nothing at all.
- **Availability UX.** The home screen warns when the active model cannot answer, with the recovery step,
  instead of letting the user discover it by sending a message that fails.

### Two API findings that changed the design

Checked against Apple's live documentation, and both are the kind of thing that would have compiled
wrong or shipped wrong:

1. **`LanguageModelSession.Usage` is iOS 27 only** — the `Usage` type is beta-only, so `Response.usage`
   is unavailable on iOS 26. The Apple provider reports `nil` usage rather than guessing. No real loss:
   §67's cost controls exist for metered cloud providers, and on-device inference is free.
2. **`Prompt.init` and `Instructions.init` take result builders, not strings** —
   `init(@PromptBuilder _ content: () throws -> Prompt)`. `Prompt("text")` would not compile;
   `Prompt { text }` does, because `String` reaches `PromptRepresentable` through `Generable`.

Also confirmed: `GenerationOptions(samplingMode:temperature:maximumResponseTokens:)` is back-deployed to
iOS 26 while the `toolCallingMode:` variant is iOS 27 and has no default for that label — so there is no
overload ambiguity on either SDK.

### Tests added

| Suite | Covers |
|---|---|
| `ModelRouterTests` | On-device pinning across every AI mode, fail-closed for pinned purposes, all three modes, offline behaviour, context-overflow escalation, preference order, the three "nothing usable" error paths, transient-reason preference, provider states, availability caching and invalidation |
| `AssistantOrchestratorTests` | A full turn end to end against real stores; conversation creation and titling; multi-turn history reaching the provider; input normalisation; empty-input refusal; identity and honesty rules in instructions; the explicit no-context statement; **context selectivity** (Blake without Jennifer); fact filtering; memory-off suppression; standing instructions; sensitivity; model failure, unavailability and empty-response handling; failures excluded from replayed history; event ordering; context item counts; silent cancellation; the working-memory bound; message assembly |
| `ConversationStoreTests` | Create/read/rename/pin/summarise/archive/delete, title derivation and preservation, resume window, per-conversation sequence numbers with colliding timestamps, supplied ids, in-place updates, working-memory window excluding failures, candidate status, archive search and excerpting |
| `AppleProviderTests` | Availability mapping and transience, prompt rendering for single turns / history / tool results / empty requests, instructions never leaking into the prompt, option mapping, error fallback |

`AssistantOrchestratorTests` is the important one: it exercises the real conversation store, the real
personalization engine and the real router, with only the model doubled.

### Known limitations

| Not working | Lands in |
|---|---|
| Token-by-token streaming. The provider answers in one piece and inherits the protocol's default `stream`. | Phase 3 |
| Session reuse and `prewarm()`. A fresh session per request costs prompt re-processing. | Phase 3 |
| Voice input and spoken replies | Phase 5 |
| History browsing and archive-search UI. The store and search are done; nothing surfaces them. | Phase 6 |
| Memory extraction, retrieval ranking, forget commands | Phase 7 |
| iCloud sync | Phase 9 |
| Tools, Activity rows | Phase 10 |
| App Intents, Siri, Shortcuts, Action Button | Phase 11 |
| Calendar, Reminders, Weather, Contacts, Location | Phase 12 |

Two deliberate deferrals worth naming:

- **Streaming was not guessed at.** `ResponseStream`'s element shape changed between the iOS 26.0 release
  and the current documentation generation — the docs now show a `Snapshot` with `.content`, where the
  original release yielded `Content.PartiallyGenerated` directly. Writing either one blind gives a 50%
  chance of a compile error and no way to tell which from here. §74 puts streaming in Phase 3 anyway, so
  it waits for a real SDK. `ConversationController` already handles `.textDelta`, so Phase 3 is a provider
  change only.
- **`Transcript`-based history was not guessed at either.** `Transcript.Prompt` and `Transcript.Response`
  would be the correct way to give the session real multi-turn structure, but `Transcript.Response`
  requires an `assetIDs` argument whose construction is not documented publicly. Rendering history into
  the prompt uses only verified API and is consistent with the store.

### Compile risks

New in this phase, most likely first:

1. **`Prompt { promptText }` / `Instructions { instructions }`.** String-in-builder relies on
   `String: Generable → ConvertibleToGeneratedContent → PromptRepresentable`. Documented transitively
   rather than as a direct conformance. If it fails, the fix is one line per site.
2. **`response.content` on `Response<String>`.** Verified as `let content: Content`, so `String` here.
3. **`nonisolated func stream` on the orchestrator.** Needed because the protocol requirement is
   synchronous. If strict concurrency objects to the `@Sendable` emit closure, the alternative is making
   the protocol requirement `async`.
4. **`@Query` built in `TranscriptView.init` with a captured `conversationID`.** The documented way to
   scope a query to a runtime value, but `$0.conversation?.id == conversationID` traverses an optional
   to-one relationship inside `#Predicate`. If that is rejected, the fallback is a stored
   `conversationID` column on `Message` alongside the relationship.
5. **`SwiftDataConversationStore` conforming to a 20-member protocol via `@ModelActor`.** Same
   consideration as the Phase 1 stores.
6. **`GenerationError` deprecation warnings** under an iOS 27 SDK, as flagged in Phase 1. Warnings only.

### Remaining issues

- Still not compiled. Every behavioural claim rests on tests that have not run.
- `AppEnvironment` constructs a real `NetworkMonitor` in its initialiser, which starts an `NWPathMonitor`
  at launch. Cheap, but it is a side effect in a container's `init`; if it proves awkward it should move
  behind a `start()` call from `load()`.
- No conversation list UI yet, so `recentConversations` and `searchMessages` are exercised only by tests.
- `ConversationController.streamingText` is written but nothing produces deltas until Phase 3.

### Next implementation step

**Phase 3 — Orchestration polish, on a machine with Xcode.**

1. Build. Fix what the compiler finds, starting with the risks above.
2. Verify `ResponseStream`'s element type against the SDK, then implement real streaming in
   `AppleFoundationModelProvider.stream`. The consumer side is already written.
3. Verify `Transcript.Prompt` / `Transcript.Response` initialisers; if they are workable, move history
   into the session transcript and add `prewarm()`.
4. Add a rolling conversation summary so threads longer than the working-memory window stay coherent.
5. Split `PersonalizationContext` into stable instructions and per-turn context, so a reused session can
   keep its cache warm across turns.

---

## Phase 1 — Foundation

**Status: complete, not yet compiled.**

Authored in a Linux container with no Swift toolchain, so nothing here has been through a compiler.
The first `⌘B` in Xcode is part of this phase's acceptance, and the compile risks below are where to
look if it fails.

### Files created

**Project (6)**
`AURA.xcodeproj/project.pbxproj` · `AURA.xcodeproj/xcshareddata/xcschemes/AURA.xcscheme` ·
`project.yml` · `Configuration/AURA.entitlements.template` · `.gitignore` · `README.md`

**Resources (3)**
`Assets.xcassets/Contents.json` · `AppIcon.appiconset/Contents.json` · `AccentColor.colorset/Contents.json`

**App (4)**
`App/AuraApp.swift` · `App/AppEnvironment.swift` · `App/RootView.swift` · `App/MainTabView.swift`

**Core — support (6)**
`Support/AuraLog.swift` · `Support/AuraError.swift` · `Support/JSONValue.swift` ·
`Support/AuraDefaults.swift` · `Support/TextTokenization.swift` · `Support/FeatureStage.swift`

**Core — storage, security, permissions (6)**
`Storage/AuraSchema.swift` · `Storage/PersistenceController.swift` · `Storage/SyncConfiguration.swift` ·
`Security/SecureCredentialStore.swift` · `Permissions/AuraPermission.swift` ·
`Permissions/PermissionManaging.swift`

**Core — AI (5)**
`AI/Providers/LanguageModelProvider.swift` · `AI/Providers/ModelAvailability.swift` ·
`AI/Providers/MockLanguageModelProvider.swift` · `AI/Routing/ModelRouter.swift` ·
`AI/Orchestration/AssistantOrchestrating.swift`

**Core — personalization (5)**
`Personalization/PersonalityEngine.swift` · `Personalization/SensitivityClassifier.swift` ·
`Personalization/PersonalizationEngine.swift` ·
`Personalization/AssistantProfile/AssistantProfileStore.swift` ·
`Personalization/UserProfile/UserProfileStore.swift`

**Core — memory, tools, voice, conversation, activity (13)**
`Memory/Storage/MemoryStoring.swift` · `Memory/Retrieval/MemoryRetrieving.swift` ·
`Memory/Extraction/MemoryExtracting.swift` · `Memory/EmbeddingProvider.swift` ·
`Tools/AssistantTool.swift` · `Tools/ToolRegistry.swift` · `Tools/ToolExecuting.swift` ·
`Tools/ToolRiskLevel.swift` · `Voice/VoiceState.swift` · `Voice/SpeechRecognitionService.swift` ·
`Voice/SpeechSynthesisService.swift` · `Conversation/ConversationStoring.swift` ·
`Activity/ActivityLogging.swift`

**Models (12)**
`DomainEnums.swift` · `AssistantProfileSnapshot.swift` · `AssistantProfile.swift` ·
`UserProfile.swift` · `PersonProfile.swift` · `Conversation.swift` · `MemoryItem.swift` ·
`MemoryCandidate.swift` · `Project.swift` · `ToolExecution.swift` · `ActivityRecord.swift` ·
`KnowledgeDocument.swift`

**Features (20)**
`Shared/PendingFeatureNotice.swift` · `Shared/ErrorAlert.swift` ·
`Assistant/AssistantHomeView.swift` · `Assistant/AssistantOrbView.swift` ·
`Assistant/ConversationView.swift` · `Memory/MemoryHomeView.swift` · `Memory/AboutYouView.swift` ·
`Memory/PeopleListView.swift` · `Memory/ProfileFactListView.swift` ·
`Activity/ActivityHomeView.swift` · `Settings/SettingsHomeView.swift` ·
`Settings/AssistantSettingsView.swift` · `Settings/PersonalitySettingsView.swift` ·
`Settings/VoiceSettingsView.swift` · `Settings/AIModelSettingsView.swift` ·
`Settings/MemorySettingsView.swift` · `Settings/PrivacyDashboardView.swift` ·
`Settings/PermissionsSettingsView.swift` · `Onboarding/OnboardingFlowView.swift` ·
`Onboarding/OnboardingSteps.swift`

**Tests (7)**
`PersonalityEngineTests.swift` · `SensitivityClassifierTests.swift` · `PersistenceSchemaTests.swift` ·
`ProfileStoreTests.swift` · `ToolContractTests.swift` · `ModelContractTests.swift` · `SupportTests.swift`

**Docs (2)** — `docs/ARCHITECTURE.md` · `docs/BUILD_LOG.md`

**Total: 78 Swift files, ~14,300 lines.**

### Files modified

None. First commit.

### Features working

These are genuinely functional, not scaffolded:

- **Onboarding**, seven screens. Names the assistant, picks and fine-tunes a personality with a live
  preview, optionally captures the user's name, sets memory policy and AI mode. Every step commits as it
  is left, so quitting halfway keeps what was chosen. No system permissions requested.
- **Assistant naming.** The chosen name drives the tab bar, navigation titles, greetings, and the first
  line of generated prompt instructions. Nothing hard-codes "AURA".
- **Personality customisation.** Seven presets, four independent style dials, free-text custom
  description, greeting style, adaptation toggle. Adjusting any dial promotes the configuration to
  Custom, which is what Custom means.
- **`PersonalityEngine`.** Complete and pure. Generates identity, style, sensitivity and honesty
  instruction blocks, greetings, and the hand-written style previews.
- **`SensitivityClassifier`.** Complete. Detects sensitive and urgent topics from text, and escalates
  from retrieved memory categories.
- **"What AURA Knows About You".** Fully editable: name, pronouns, work, education, location, interests,
  hobbies, goals, routines, places, standing instructions. Facts grouped by category, with pin, archive,
  delete, add and correct. People with relationship, education, work, facts, interests, preferences and
  dates. Correcting a value supersedes it rather than overwriting.
- **`AssistantProfileStore` / `UserProfileStore`.** Real `@ModelActor` stores with singleton
  reconciliation, partial-mutation semantics, and change detection that avoids pointless `updatedAt`
  churn.
- **`PersistenceController`.** Real container with a versioned schema, a migration plan, and a
  fall-back-to-memory path that tells the user rather than pretending to save.
- **`KeychainCredentialStore`.** Real, with update-then-add semantics so a failed write cannot leave the
  user with no key and no error.
- **`ToolRegistry`.** Real actor with availability filtering by permission, connectivity and risk
  ceiling, plus per-tool explanations for what is withheld and why.
- **`MockLanguageModelProvider`.** Real, covering both tool-execution styles, streaming, sequences,
  failures and echo.
- **Privacy dashboard and Permissions.** Read live state, explain each permission's purpose and its
  degradation, route to system Settings when re-prompting would do nothing.
- **Navigation shell.** Four tabs, deep links, light/dark, Dynamic Type, VoiceOver labels, Reduce Motion.

### Tests added

Seven test files, several with more than one `@Suite`, and several tests parameterised over cases.

| Suite | Covers |
|---|---|
| `PersonalityEngineTests` | Identity, honesty rules across every preset × sensitivity, humour suppression, response length, custom description precedence, standing instructions, greetings, part-of-day boundaries, preview distinctness |
| `SensitivityClassifierTests` | Normal / sensitive / urgent classification, urgent precedence, category escalation, case handling |
| `PersistenceSchemaTests` | **Schema validity**, duplicate-model check, migration plan, all fifteen models insertable, cascade deletes, `#Predicate` compilation against raw-string enums / search text / importance / captured id arrays |
| `ProfileStoreTests` | Singleton creation and idempotence, name normalisation and truncation, preset application, no-op timestamp discipline, custom-description clear, speech-rate clamping, reset identity, duplicate reconciliation, fact upsert/supersede/pin/archive/delete/search, person dedupe and alias matching, the Blake correction scenario end to end, recurring dates, wholesale deletion |
| `ToolContractTests` | All three safety tiers, escalation override, registry filtering by permission / connectivity / risk, unattended posture, unavailability reasons, id replacement, argument coercion, date parsing, JSON Schema rendering |
| `ModelContractTests` | `JSONValue` round-trip and coercion, memory currency and durability, search text, confidence hedging, access counters, conversation titling, tool-activity round-trip, ranking weights and dominant term, context assembly including the explicit no-context statement, mock provider across both tool styles and streaming |
| `SupportTests` | Name normalisation, threshold ordering, tokenisation including negation survival, overlap normalisation, proper-noun heuristic, availability states, every `AuraError` speaking, silent errors, feature staging honesty, voice state machine, credential store, permission flows |

`PersistenceSchemaTests` is the one that matters most right now: SwiftData validates a schema when the
container is created, so an invalid relationship or an unsupported attribute surfaces as a thrown error
in a test rather than as a crash on a device.

### Known limitations

Deliberate, and surfaced in the UI through `FeatureStage` rather than hidden:

| Not working | Lands in |
|---|---|
| Conversation — no model, no orchestrator, no reply. Composer disabled with an honest note. | Phase 2–3 |
| Voice input and spoken replies | Phase 5 |
| Conversation persistence | Phase 6 |
| Automatic memory, extraction, retrieval, forget commands | Phase 7 |
| iCloud sync — `.localOnly`, entitlements shipped as a template | Phase 9 |
| Tools, Activity rows, tool confirmations | Phase 10 |
| App Intents, Siri, Shortcuts, Action Button, widgets | Phase 11 |
| Calendar, Reminders, Weather, Contacts, Location | Phase 12 |
| Data export | Phase 13 |

Also incomplete by design:

- `PermissionManaging` has only `StubPermissionManager`. The real one needs AVFoundation, Speech,
  EventKit, Contacts, CoreLocation and UserNotifications — Phase 12/13, alongside the tools that use
  them. The Permissions screen therefore reflects stub state on device.
- `EmbeddingProvider` has only `UnavailableEmbeddingProvider`, which throws rather than returning zero
  vectors. Zeros would make every memory look equally similar to every query — worse than no signal.
- `KnowledgeDocument` and `UserPreference` are in the schema but unused. Adding a `@Model` later is a
  migration; adding it now, while the store is empty, is free.
- `Project` and `AssistantTask` are modelled and in the schema but have no UI yet (Phase 7–8).

### Two decisions worth flagging

**The "JARVIS-Inspired" preset is named "Refined".** The behaviour §10 asks for is implemented exactly —
highly competent, calm, quick, quietly witty, proactive without hovering, and no copyrighted dialogue or
actor imitation. The *name* is the problem: JARVIS is Marvel/Disney trademarked, and shipping it as
user-visible UI text in a distributed app invites a takedown that has nothing to do with the product.
The enum case is `PersonalityPreset.refined`. Renaming it back is a one-line change to `displayName` if
that trade is wanted.

**British spellings appear in some user-facing copy** ("humour", "favourite"), matching how the strings
were authored. Worth normalising to a single locale convention before shipping; a `LOCALIZATION_PREFERS_STRING_CATALOGS`
pass in Phase 13 is the natural place.

### Compile risks

Where the first build is most likely to complain, in rough order of probability:

1. **`AURA.xcodeproj` structure.** Hand-authored without Xcode, using `PBXFileSystemSynchronizedRootGroup`
   (folder references rather than per-file entries). If Xcode rejects it: `brew install xcodegen &&
   xcodegen generate` rebuilds an equivalent project from the checked-in `project.yml`.
2. **`@ModelActor` conformance to `async` protocols.** `AssistantProfileStore` and `UserProfileStore`
   satisfy their protocols through actor-isolated methods. If the macro's generated members clash with a
   requirement, the fix is a `nonisolated` wrapper — no design change.
3. **`ReferenceWritableKeyPath` into `@Model` properties.** The `apply(_:)` helpers set values through
   key paths, and the macro rewrites stored properties into computed ones. If key paths do not resolve,
   the fallback is explicit `if let` assignments — more verbose, same behaviour.
4. **SwiftUI `Tab(value:content:label:)`.** Used in the explicit-label form specifically because the
   first tab's title is a runtime `String`. If the initialiser signature differs, the shorthand
   `Tab(_:systemImage:value:)` with a `StringProtocol` title is the alternative.
5. **`#Predicate` with a captured `Array.contains`.** Arrays are used rather than `Set`s because
   SwiftData's `Set` support is uneven. `idArrayPredicate` in `PersistenceSchemaTests` is there to prove
   this at test time rather than in production.
6. **`Date.ISO8601FormatStyle` date-only parsing** in `ToolArguments.parseDate`. Covered by
   `parsesDates`.
7. **Strict-concurrency diagnostics in views.** Every `View` struct is explicitly `@MainActor` and
   callbacks invoked from a `Task` are `@MainActor`-typed, so non-`Sendable` captures stay in one
   isolation domain. `SWIFT_DEFAULT_ACTOR_ISOLATION` is set to `nonisolated` deliberately, so isolation
   is written down rather than inferred.
8. **`LanguageModelSession.GenerationError` deprecation** — not a Phase 1 risk, but expect warnings in
   Phase 2 when building against an iOS 27 SDK.

### Remaining issues

- Nothing compiled. Every claim above about *behaviour* rests on tests that have not run.
- `AppIcon.appiconset` has no artwork, which produces a build warning.
- `PersonalityEngine.stylePreview` covers presets, not every dial combination, so two nearby
  configurations can preview identically. Acceptable — the preview shows register, not a rendered
  answer.

### Next implementation step

**Phase 2 — Basic Intelligence.**

1. `AppleFoundationModelProvider` over `SystemLanguageModel` / `LanguageModelSession`: map
   `availability` onto `ModelAvailability`, diff cumulative stream snapshots into deltas, translate
   `GenerationError` cases onto `AuraError`.
2. `DefaultModelRouter`: honour `AIMode`, enforce `ModelRequestPurpose.isOnDeviceOnly` above the user's
   mode, fall back on unavailability with the reason attached to the `ModelRoute`.
3. A minimal `AssistantOrchestrator` — no tools, no extraction — enough for `ConversationView` to hold a
   real conversation.
4. `SwiftDataConversationStore` behind `ConversationStoring`, so turns persist as they are written.
5. Flip `FeatureFlags.textConversation` to `.live` **in the same commit** that makes it work, and enable
   the composer.
6. Tests: routing decisions under every `AIMode` × availability combination, the on-device pinning rule,
   a full orchestrated turn against `MockLanguageModelProvider`, and stream-delta assembly.
