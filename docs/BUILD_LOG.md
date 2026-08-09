# Build log

One entry per implementation stage, in the format of §77: status, files, what works, tests, known
limitations, compile risks, next step.

---

## Verification

**Commit `92c54c6` builds clean and the whole suite passes.** Confirmed on GitHub's macOS runners:
macOS 26.5.2, **Xcode 26.6**, Swift 6.3.3, iPhone 17 Pro simulator.

```
Build:  0 errors, 0 warnings
Tests:  all passing (5m 35s)
```

> **On the test count.** This file and the README used to say "210 tests in 26 suites". That number came
> from `test.sh` counting lines matching `✔`, which also matches one line per *suite* plus the run
> summary — so it was never a test count, and it drifted: the same unchanged suite reported 210 on one
> run and 241 on another. `test.sh` now parses Swift Testing's own `Test run with N tests` line, and the
> figures below are recorded as pass/fail rather than as counts. The run numbers in the table are
> genuine; only the totals were wrong.

Roughly 15,000 lines of Swift, written across two phases without a compiler, needed **four genuine
code fixes and two configuration fixes** to go green.

| Run | Build | Tests | What it found |
|---|---|---|---|
| 1 | 3 errors, 2 warnings | — | `Section(_:content:footer:)` does not exist; a dead binding; a discarded return value |
| 2 | 1 error | — | escaping closure capturing a non-escaping parameter |
| 3 | **clean** | not configured | empty `<TestPlans>` in the scheme disabled the test action |
| 4 | clean | one failure | a test asserting Phase 1's reality against Phase 2's code |
| 5 | **clean** | **all passing** | — |

### The defects, and what each one says

1. **`Section(fact.key) { … } footer: { … }` has no such initializer.** SwiftUI's title-string
   `Section` inits take only content; the header/footer forms take no title string. The only genuine
   API misunderstanding in the whole codebase.
2. **Escaping-closure capture** in `PersonDetailView.commit`. Fixed by building the mutation before the
   `Task` rather than marking the parameter `@escaping`, so only a `Sendable` value crosses in.
3. **A dead `let name` binding** in `PersonalityEngine.stylePreview`.
4. **A discarded `removeValue` result** in `InMemoryCredentialStore.delete` — made explicit rather than
   silenced, since holding a copy of a secret we were asked to delete defeats the point.
5. **The scheme's empty `<TestPlans>` element.** Declaring it at all makes Xcode ignore `<Testables>`
   entirely. A hand-authored-project-file problem, not a code problem.
6. **A stale test.** `FeatureStageTests` kept its own list of which capabilities were pending, and
   Phase 2 flipped two flags to `.live` without updating it. Fixed by deriving the tests from
   `FeatureFlags.all`, so the same drift cannot recur — the fix removed the hazard, not just the
   symptom.

### Which Phase 1 predictions held

The eight compile risks listed under Phase 1 were ranked guesses. Outcome:

| Predicted risk | Real? |
|---|---|
| Hand-written `AURA.xcodeproj` rejected by Xcode | **No** — read fine; XcodeGen fallback never triggered |
| `@ModelActor` conformance to async protocols | No |
| `ReferenceWritableKeyPath` into `@Model` properties | No |
| `Tab(value:content:label:)` signature | No |
| `#Predicate` with a captured `Array.contains` | No |
| `Date.ISO8601FormatStyle` date-only parsing | No |
| Strict-concurrency diagnostics in views | **Partly** — one escaping-closure capture |
| `GenerationError` deprecation warnings | Not yet — no warnings on Xcode 26.6 |

Every Foundation Models API checked against Apple's documentation before use compiled as expected:
`Prompt { }` and `Instructions { }` builders, `response.content`, the availability enums,
`GenerationOptions(temperature:maximumResponseTokens:)`. The doc-verification pass paid for itself; the
one API mistake was in a SwiftUI initializer that was *not* verified that way.

### What green does and does not mean

It means the schema is valid (all 15 models, cascade deletes, every `#Predicate` shape retrieval
depends on), a full orchestrated turn runs end to end against a mock provider, context selectivity
holds, and the safety tiers behave.

It does **not** mean AURA has been used. No test can run Apple's on-device model — that needs real
hardware with Apple Intelligence enabled. The first genuine conversation is still ahead.

---

## Phases 10, 12 and 13 — Action, the system, and getting your data out

Three phases in one sitting, in that order. Phase 11 (App Intents) is skipped for now and Phase 9
(CloudKit) remains deliberately unstarted.

| Phase | State |
|---|---|
| 10 — Tools | **Complete.** Executor, gates, confirmation UI, the Apple `Tool` bridge, and three memory tools. `tools` live. |
| 12 — System | Calendar, reminders and contacts. `systemIntegrations` live. Weather and travel time deliberately absent. |
| 13 — Privacy | Export, the audit trail's writer, and a wipe that actually wipes. `dataExport` and `activityLog` live. |

### Two real defects found in already-shipped code

Neither was in the new work, and both are the same shape — something that reported success it had not
earned.

1. **`ToolExecutionRecord.activityNote` hard-coded `succeeded: true`.** A tool the user *declined* would
   have appeared in the transcript with a tick beside it. Now derived from `wasDeclined`.
2. **"Delete all my data" did not delete most of the data.** It cleared the profile and the Keychain
   only, while the confirmation dialog promised "every memory and every conversation". Memories,
   transcripts and the audit trail all survived a wipe the user had been told was total. Every store is
   now listed explicitly, and a wipe that fails halfway says so instead of reporting success.

The second one is worth dwelling on: it had been in the repo since Phase 1, the dialog text was written
at the same time as the incomplete implementation, and no test caught it because no test asserted that
the promise and the behaviour matched. The test that now exists asserts the stores are empty afterwards,
not that the function was called.

### A design problem the compiler could not have found

Phase 12 mapped EventKit's write-only calendar access to `PermissionStatus.limited`, which is truthful —
AURA really can add an event and really cannot read one. But `.limited.isUsable` is `true`, and tool
availability was a flat `Set<AuraPermission>`, so `read_calendar` was being *offered* to the model and
then refused by the gate. EventKit returns an empty array under write-only access, indistinguishable
from a clear day, so the alternative failure was worse: AURA telling someone their day is free when it
cannot look.

Fixed with `AssistantTool.requiresFullPermissionAccess` and a `partiallyGrantedPermissions` set on
`AvailabilityCriteria`. Write-only access now offers the create tool, withholds the read tool, and the
gate agrees with the offer. Both sides read from one status snapshot so they cannot describe different
moments.

### What the API-verification passes caught before the compiler did

| Claim checked | What the docs said |
|---|---|
| `DynamicGenerationSchema(name:description:anyOf:)` | `anyOf` takes `[DynamicGenerationSchema]`, not `[String]` — the enum case needs `GenerationGuide.anyOf` instead |
| `Transcript.ToolDefinition(tool:)` | Exists — needed, because instructions ride in the transcript here, so `toolDefinitions: []` would have handed the session tools the model was never told about |
| `String`/`Int`/`Double`/`Bool`: `Generable` | All four confirmed on the stdlib type pages, not the protocol page |
| `EKReminder.dueDateComponents` | `DateComponents?`, and `DateComponents.date` is `nil` without a calendar — a dated reminder would have read as undated |
| EventKit access requests | Documented as completion-handler form; the `async` overloads are compiler-generated, so the documented shape is used |

### What only the compiler could tell us

| Run | Failure |
|---|---|
| 32 | `AuraError.toolIterationLimitReached` takes `limit:` — thrown without it, the case name is a function value |
| 33 | `GenerationSchema.name` is **iOS 27 and beta**, so not on the iOS 26 SDK. The docs page listed the member; the availability annotation was on the member's own page |
| 35 | Four Swift 6 concurrency errors in the EventKit bridge: a non-`Sendable` `[EKReminder]` crossing a continuation, `EKEventStore` sent out of its own actor, two callbacks missing `@Sendable` |

Run 33's is the instructive one. Verifying that a member exists is not the same as verifying it exists
*on the SDK being built against*, and the availability annotation lives on the member's page rather than
the type's. That is now part of the check.

### Still true

Phase 12 is the first phase where the gap between "verified" and "works" is wide. A simulator has no
calendar data, no address book and grants no real authorization, so CI can prove the tools compile and
that the policy deciding what the user gets told is correct — and can prove nothing at all about reading
a real calendar. Add the standing caveat: the on-device model has still never called a tool, the
microphone has never opened, and nothing has been spoken aloud. **AURA is thoroughly verified and has
never been used.**

---

## Phases 5, 6 and 7 — status

**Verified by CI run 24: build clean, whole suite passing.** The first fully green run since Phase 2, and it
covers nine commits at once.

| Phase | State |
|---|---|
| 5 — Voice | Services, permissions and UI wiring done; `voiceInput`/`voiceOutput` live. **Never run against a microphone.** |
| 6 — History | Complete. Browsing, archive search, rename/pin/archive/delete. |
| 7 — Memory | **Complete.** Retention policy, store, retrieval, extractor and consolidator all written and wired; `memory` is live. Never run against the real model. |

### What nine unverified commits actually cost

Voice through the memory store accumulated without a compile check, because each push cancelled the run
before it. Five rounds to clear:

| Round | What it was |
|---|---|
| 1 | `#Predicate` body with an `if let` — a predicate must be one expression |
| 2 | `@MainActor` on a type isolates its *static* members too, so three pure helpers were uncallable from a synchronous test |
| 3 | Two memberwise initialisers written in prose order instead of declaration order |
| 4 | A test asserting "voice is not live yet" — it failed *because the project shipped voice* |

No design defects, and no invented Apple API. The failures were Swift-dialect slips and one stale
expectation, which is the pattern worth noting: the doc-verification passes are doing their job, and what
remains is the stuff only a compiler can tell you.

Two habits came out of it. When the compiler names some call sites, check *all* of them mechanically — that
found nothing further in the argument-order case but was the right move regardless. And a test that pins the
current phase will fail on the commit that makes progress, so assert the invariant instead; that mistake has
now been made twice in the same suite.

### Still true, and the thing that matters most

None of this has run on a phone. The on-device model has never answered, the microphone has never opened,
and no reply has ever been spoken aloud. 267 tests pass against mocks; a simulator has no Apple Intelligence
and no audio input. **AURA is thoroughly verified and has never been used.**

---

## What looking at the screens found

CI run 7 produced the first images of AURA (`docs/SCREENSHOTS.md`). Worth recording plainly: the app had
been **green for two runs — 0 errors, 0 warnings, whole suite passing — while shipping four visible
defects.** None of them was the kind of thing a test suite catches, and all four were obvious within
seconds of looking at a picture.

| What | Where | Cause |
|---|---|---|
| Selection rows rendered blue and read as disabled | AI Model, Personality, Assistant settings | `.primary` / `.secondary` are *hierarchical* styles. Inside a default-styled `Button`, they resolve against the button's **tint**, not the label colour. Onboarding got this right with `.buttonStyle(.plain)`; the settings screens never did. |
| Long field values truncated to an ellipsis | `LabeledTextField` — "Studies", "Work" | Single-line `TextField`. "Mechanical Engineering at the University of Tennessee" is a realistic value and was unreadable in the field meant to display it. |
| Two `onSubmit` handlers that could never fire | `PersonalitySettingsView`, and one introduced then removed here | A vertical-axis `TextField` treats Return as a newline, so `onSubmit` never fires and `submitLabel(.done)` labels a no-op. |
| Orb ring visibly off-centre from its core | Onboarding welcome screen only | Animations started in `onAppear`, racing the first layout pass — see below. |

The button on the "I'm Nova." screen also said **"Start talking"** on a screen that states voice is not
wired up yet. Now "Start chatting", which is what actually works.

### The orb: how it was diagnosed without a debugger

On the welcome screen the ring and the core were offset by roughly a third of the orb's width. Every
other screen showing the same view — ready, home, home in dark mode — rendered it correctly concentric.

The layers cannot be off-centre by construction: three `Circle()`s in a `ZStack` with symmetric padding,
and neither `rotationEffect` nor `scaleEffect` can translate a centred circle. The distinguishing feature
of the welcome screen is that it is the only one where nothing forces a **second layout pass** — the
other onboarding screenshots reach their step by mutating state, which relays out the content.

That gave the hypothesis: the `repeatForever` animations were installed in `onAppear`, against geometry
that was not yet final. The fix moved them to `.task` and stated every transform anchor explicitly.

It was recorded here as a hypothesis rather than a diagnosis, because it was reasoned from an image and
the source without ever being reproduced — there is no Mac here to run a simulator against. **CI run 8
confirmed it:** the ring is concentric, and the only images that changed were the nine screens the fixes
touched. Worth keeping the shape of this, since it will recur: with no debugger, the screenshot is the
instrument, and "which screens does it *not* happen on" is the question that locates the cause.

### The lesson worth keeping

A green build says the code is *valid*. It says nothing about whether it is *right*. Four defects lived
comfortably behind a fully passing suite, and the screenshot pipeline earned its cost on its first run.

A postscript in the same spirit: the run that verified these fixes also printed a test count that
contradicted the one in the README, which is how the bad counter in `test.sh` was found. The tooling that
reports on the work needs the same scepticism as the work.

---

## Phase 3 — Streaming and transcript history

**Status: compiled and tested.** Verified by CI run 11 — 0 errors, 0 warnings, **220 tests in 26 suites**
passing. That is the first test count from the repaired counter in `test.sh`; the numbers this file used to
quote, 210 and 241, were both artefacts of the old one.

Run 10 built clean but failed one test. It was this stage's own new test, and it failed on the guard
assertion deliberately put there to check the test's own premise — details under *Tests* below.

Two of Phase 3's five items. The remaining three — `prewarm()`, a rolling conversation summary, and
splitting `PersonalizationContext` into stable instructions plus per-turn context — are next.

### Real token streaming

`AppleFoundationModelProvider` no longer inherits the protocol's one-delta default. It uses
`streamResponse(to:options:)` and diffs Apple's **cumulative** snapshots into the deltas
`ModelStreamEvent` promises.

The consumer side needed nothing: `ConversationController` already accumulated deltas into
`streamingText` and `ConversationView` already rendered them as a live bubble. What changed is that the
orchestrator now generates through `provider.stream` instead of `provider.send`, so those events finally
carry real incremental text. A provider with no native streaming still inherits the default that emits
one delta, so the orchestrator has one path rather than a branch on whether streaming is genuine.

Two decisions worth recording:

**`ModelStreamEvent` gained `textReplaced`.** Snapshot streams are only append-only by convention, not by
documented guarantee. A delta cannot be retracted, so a provider whose output stops extending what it
already sent needs a way to say "discard that, here is the whole reply". Without it, a revision would
concatenate into nonsense on screen.

**`.finished` is the authority on the final text, not the accumulated deltas.** They agree in the normal
case, but if they ever disagree the persisted message must match what the provider concluded rather than
what the UI happened to assemble. A stream that ends without `.finished` throws instead of persisting
whatever text arrived. Testing this needed a mock that diverges deliberately; see *The test that caught
itself* below.

### History as a Transcript, not as prose about history

Prior turns used to be rendered into the prompt as a labelled block — `Earlier in this conversation:
User: … You: …`. They are now replayed as a real `Transcript` via
`LanguageModelSession(model:tools:transcript:)`, so the model sees actual role separation, and the prompt
contains only the turn being taken.

The store is still the single source of truth. The transcript is *derived from it* on every request
rather than accumulated alongside it — which is what the Phase 2 note about "two sources of truth" was
protecting, and it survives this change intact.

Instructions ride in the transcript because `init(model:tools:transcript:)` takes no `instructions`
parameter. That is the only way in, and it was verified rather than assumed.

### Every Apple API verified before use

Per the standing rule, each signature was checked against Apple's documentation rather than recalled. The
table is in the header of `AppleFoundationModelProvider.swift` so it sits next to the code that depends
on it: `streamResponse(to:options:)` returning `sending ResponseStream<String>`, `ResponseStream`'s
`Element` being `Snapshot<Content>`, `Snapshot.content` being `Content.PartiallyGenerated`, and the
initialisers for `Transcript`, `Transcript.Instructions`, `Transcript.Prompt`, `Transcript.Response` and
`Transcript.TextSegment`.

**One thing could not be verified from documentation, and the compiler settled it.** `Generable` declares
`associatedtype PartiallyGenerated: ConvertibleFromGeneratedContent = Self`, and Apple does not publicly
document `String`'s conformance — so whether `Snapshot.content` is a `String` was unknown. The code annotates
it `String` explicitly for exactly that reason: a wrong resolution fails the build and names the real type,
which is a loud failure chosen over `String(describing:)` that would compile against anything and ship
mangled text.

**It compiled.** `String.PartiallyGenerated` is `String`, the protocol's default applies, and Apple simply
does not publish the conformance. Now known from a compiler rather than assumed from a default — and the
annotation stays, because it is what would catch the change if a future SDK overrode it.

### Tests added

`resolveDelta` is pure and unit-tested, because a diffing bug duplicates or drops text on screen and no
compiler catches it. Beyond the three obvious cases there is a property test that feeds every prefix of a
sentence through as one snapshot per character and asserts the reassembly is byte-identical to the
original. `makeTranscript` is tested for entry shape, for excluding the live turn, and for omitting a
blank instructions entry.

#### The test that caught itself

The test for "the persisted answer comes from `.finished`, not from the deltas" needs a provider whose
deltas genuinely disagree with its final text. The first version tried to get that for free from
`.respond("one  two")`, reasoning that the mock's split-on-space streaming would reassemble the doubled
space as three. **It does not** — splitting and rejoining is lossless, and the arithmetic behind that guess
was simply wrong.

Nothing about the invariant was broken. What was broken was the test: it would have passed while
distinguishing nothing, and it would have sat there indefinitely looking like coverage. What caught it was
the guard assertion written alongside it — the one asserting that the two values *do* differ, on the
principle that a test resting on a premise should check the premise.

The fix is a `streamDivergently(deltas:thenFinish:)` behaviour on the mock, which diverges by construction
instead of by accident. Every other mock behaviour derives its deltas *from* the final text, so no test built
on them can distinguish the two — that limitation is now stated where the behaviour is declared.

The general lesson, and the reason it is written down: a test whose premise is an assumption about *other
test infrastructure* is worth exactly as much as that assumption. Asserting the premise is what turns a test
that would have quietly proven nothing into one that fails loudly the day it stops being valid.

### Known limitations

- Streaming has never run against the real model. A simulator has no Apple Intelligence, so CI can only
  prove the code compiles and that the mock path behaves; the deltas a real device produces are unseen.
- Tool results replay as labelled prompts rather than `Transcript.ToolOutput`, because constructing one
  honestly needs the tool-call entry it answers and tools are Phase 10.
- Token usage is still `nil` on this provider — `LanguageModelSession.Usage` is iOS 27.

### Stable and per-turn context, split

`PersonalizationContext` now exposes two halves instead of one blob:

- `stableInstructions` — personality, the user's standing instructions, their name. Identical on every turn
  of a conversation.
- `turnContext(now:)` — what retrieval found, and the clock. Rebuilt every turn by definition.

`modelInstructions(now:)` is still there and is exactly the two joined, so nothing that audits "what the
model was told" has to know about the split. `ModelRequest` mirrors it with `instructions` +
`turnContext`, and `combinedInstructions` for providers that cannot exploit the difference.

The Apple provider puts the stable half in the transcript's instructions entry and the per-turn half with
the prompt. That is the whole point: the instructions entry stays byte-identical between turns, so it can
be prewarmed and cached, while the material that changes every turn rides with the prompt that changes
anyway. A test asserts the per-turn context does **not** reach the instructions entry, because if it leaked
there the cached prefix would be invalidated every turn and the split would buy nothing.

There is also a test that the split is lossless — the two halves joined equal what a provider used to
receive. Anything that fell out of both halves would be context silently dropped, and no test of either
half alone would notice.

### Prewarming

`LanguageModelProvider.prewarm(instructions:)`, defaulting to a no-op, implemented on the Apple provider
via `session.prewarm()`. `AssistantOrchestrating.prewarm()` routes and warms the provider the next turn
would use; `ConversationController` calls it in a detached task when the conversation screen opens, so the
screen never waits on it.

It deliberately runs **no retrieval** — retrieval needs a message that has not been typed yet, and doing it
speculatively would both waste work and assemble personal context for a request that may never happen. Only
the stable half is warmed, which is precisely the part that will be identical when the real turn arrives.

Every failure is swallowed by contract. A warm-up that reported errors to the user would be worse than no
warm-up.

### One CI fix, from a mistake this stage made

The GitHub API's per-step `conclusion` is **not** the result for a `continue-on-error` step: a failed step
reports `conclusion: "success"`, and only `outcome` says `failure`. Reading `conclusion` is how run 10's
test failure got reported as passing before the log was checked properly.

Both report steps now print `STEP OUTCOME build=…` / `STEP OUTCOME test=…` into the job log, so the real
result is greppable and no reader has to know that distinction to avoid being misled by it.

### Rolling conversation summary

The last Phase 3 item. Working memory is capped at twelve turns, so before this a long thread silently
forgot its own beginning while still appearing to remember everything — the failure mode §78 cares most
about, because the assistant has no way to know it has forgotten.

Turns that age out are now condensed into `Conversation.summary` and replayed to the model. No schema change
was needed: `Conversation.summary` and `ConversationStoring.updateSummary` have been there since Phase 1.

**Where the summary goes.** `ModelRequest.conversationSummary`, replayed by the Apple provider as a labelled
entry positioned *before* the surviving turns — because that is when it happened. Appended after them it
would read as the most recent thing said. There is a test asserting the order for exactly that reason.

It is deliberately **not** folded into `instructions`: the summary grows with the thread, and mixing it into
the cacheable prefix would invalidate that prefix on every turn, undoing the split from the previous stage.

**When it refreshes.** After `.finished` is emitted, so the user already has their answer. Sequenced rather
than detached, which costs nothing the user can perceive — the event stream simply stays open a moment
longer — and makes the behaviour testable instead of a race.

**How incremental works, and the bound.** The input is the previous summary plus the most recently aged-out
turns, never the whole history: a thread hundreds of turns long would otherwise overflow the context window
of the model being asked to summarise it.

Coverage is not tracked in the store. There is no field for it, and adding one means a schema version for a
single integer. Instead this relies on running after *every* turn, which keeps the number of newly-aged-out
turns at roughly two — well inside the twelve fed back in. The honest consequence: **roughly six consecutive
failed refreshes could let a turn age out without ever reaching a summary.** It is bounded, it self-heals on
the next success inside the window, and it is written down here rather than presented as exact.

Also true and worth stating: the refresh reads all of a conversation's messages each turn once the window is
exceeded, which is O(n) per turn. Fine at conversation scale, and the place to look first if long threads
ever feel slow.

**What the prompt guards against.** The summarisation instructions push against invention harder than
anything else in the codebase, because a summary that adds a detail nobody said becomes indistinguishable
from something the user actually told AURA — and is then recalled as fact for the rest of the conversation.
That is the §78 failure with the longest reach. `summaryPrompt` is `static` and pure so the exact text is
assertable, including that rewriting an existing summary and starting a fresh one are different
instructions.

### Phase 3 status

**Complete and verified.** All five items — streaming, transcript history, the context split, prewarming and
the rolling summary — confirmed by CI run 24.

### Next implementation step

Phase 3 is feature-complete once the pending run is green. After that the open choices are Phase 5 (Voice),
Phase 7 (automatic memory extraction), or TestFlight — none of which depends on the others.

---

## Phase 2 — Basic Intelligence

**Status: complete, compiled and tested.** Verified by CI run 5 — see [Verification](#verification).

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

**Status: complete, compiled and tested.** Verified by CI run 5 — see [Verification](#verification).

Authored in a Linux container with no Swift toolchain, so none of it had been through a compiler when
it was written. The "compile risks" listed below were predictions made at that time; the Verification
section records which of them were real. Keeping both is the point — a prediction is only worth
anything next to its outcome.

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
