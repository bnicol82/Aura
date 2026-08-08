# AURA

A private, on-device-first personal AI assistant for iPhone.

AURA is a native SwiftUI application built around six pillars: **Intelligence, Personality,
Memory, Action, Privacy, Continuity**. It is not a chat client — it is a personal AI layer that
remembers what matters to you, speaks in a voice you choose, and can actually do things.

> **Status: Phase 2 (Basic Intelligence) complete.** AURA holds a real typed conversation: input goes
> to Apple's on-device model through the orchestrator, the answer persists, and the transcript renders
> from the store. See [`docs/BUILD_LOG.md`](docs/BUILD_LOG.md) for what works today, what is
> deliberately deferred, and what comes next. Nothing in this repository has been compiled yet — it was
> authored in a Linux container with no Swift toolchain. Treat the first `⌘B` in Xcode as part of
> acceptance, and see the build log's ranked compile risks if it fails.

## Requirements

| | |
|---|---|
| Xcode | 26.0 or later |
| Deployment target | iOS 26.0 |
| Language | Swift 6 (strict concurrency) |
| Device for full features | iPhone with Apple Intelligence enabled |

AURA runs on any iOS 26 device. On hardware without Apple Intelligence it degrades gracefully:
memory, profiles, conversation history, search and the UI all work; language-model replies require
either an eligible device or a deliberately configured cloud provider.

## Getting started

```bash
git clone <this repo>
cd Aura
open AURA.xcodeproj
```

Then, once, in Xcode:

1. Select the **AURA** target → **Signing & Capabilities** → set your own **Team**.
2. Change `PRODUCT_BUNDLE_IDENTIFIER` from `com.aura.assistant` to a bundle ID you own.
3. Build and run (`⌘R`). Tests: `⌘U`.

### If the Xcode project will not open

`AURA.xcodeproj` was hand-authored (no Xcode available in the authoring environment) using
Xcode 16+ *synchronized file groups*, so it references folders rather than individual files.
If it is rejected, regenerate it from the checked-in declarative spec:

```bash
brew install xcodegen
xcodegen generate      # reads project.yml, rewrites AURA.xcodeproj
```

`project.yml` and `AURA.xcodeproj` describe the same project. `AURA.xcodeproj` is the one you
open day to day; `project.yml` exists purely as a recovery path.

### iCloud / CloudKit

CloudKit sync is **off in Phase 1** and lands in Phase 9. The entitlements are checked in as
`Configuration/AURA.entitlements.template` but are intentionally *not* wired to
`CODE_SIGN_ENTITLEMENTS`, so the project builds and signs without an iCloud container. To turn
sync on early, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md#9-cloudkit-strategy).

## Layout

```
AURA/
  App/              app entry point, dependency container, navigation shell
  Core/
    AI/             LanguageModelProvider, ModelRouter, orchestration contracts
    Personalization/ assistant identity, personality engine, profile stores
    Memory/         memory storage, retrieval, extraction, embeddings
    Tools/          AssistantTool, registry, executor, safety levels
    Voice/          speech recognition + synthesis contracts, voice state machine
    Storage/        SwiftData container, schema, sync configuration
    Security/       Keychain-backed credential store
    Permissions/    permission model
    Support/        logging, errors, JSON, defaults
  Models/           SwiftData persistent models + Sendable snapshots
  Features/         Assistant, Memory, Activity, Settings, Onboarding
AURATests/          Swift Testing suites
docs/               architecture and per-stage build log
```

## What works today

| | |
|---|---|
| Onboarding, assistant naming, personality | Phase 1 |
| "What AURA Knows About You" — editable profile, people, categorised facts | Phase 1 |
| Typed conversation against Apple's on-device model | Phase 2 |
| Model routing across all three AI modes, with on-device pinning for extraction | Phase 2 |
| Persisted conversations, multi-turn history, archive search | Phase 2 |
| Selective context assembly — only what a request needs reaches the model | Phase 2 |

Voice, automatic memory, tools, iCloud sync and App Intents are declared pending in
`FeatureFlags` and the UI says so rather than failing quietly.

## Privacy posture

- Local-first. Everything works offline that technically can.
- On-device model preferred; cloud providers are opt-in, per-request, and never receive the whole
  memory database — only the context the retrieval engine judged relevant to the current request.
- No raw microphone audio is persisted.
- No personal content is written to `OSLog` at default privacy.
- Secrets live in the Keychain, never in SwiftData or CloudKit records.
