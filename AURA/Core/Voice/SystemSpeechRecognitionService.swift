import AVFoundation
import Foundation
import Speech

/// `SpeechRecognitionService` over iOS 26's `SpeechAnalyzer` + `SpeechTranscriber` (§38).
///
/// ### APIs verified against Apple's documentation before use
/// Checked rather than recalled, for the same reason as the model provider — a plausible-looking wrong
/// signature is this codebase's most likely failure:
///
/// | API | Verified shape |
/// |---|---|
/// | `SpeechTranscriber.init(locale:preset:)` | iOS 26.0+, `Preset.progressiveTranscription` for live audio |
/// | `SpeechTranscriber.results` | `some Sendable & AsyncSequence<Result, any Error>` |
/// | `SpeechTranscriber.Result` | `text: AttributedString`, `isFinal: Bool`, `alternatives: [AttributedString]` |
/// | `SpeechTranscriber.isAvailable` / `.supportedLocales` / `.installedLocales` | static |
/// | `SpeechAnalyzer.init(modules:options:)` | `options` is optional |
/// | `SpeechAnalyzer.start(inputSequence:)` | `async throws` |
/// | `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()` / `.cancelAndFinishNow()` | `async throws` / `async` |
/// | `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` | `static`, `async` |
/// | `AnalyzerInput.init(buffer:)` | takes `AVAudioPCMBuffer` |
/// | `AssetInventory.assetInstallationRequest(supporting:)` | `async throws -> AssetInstallationRequest?` |
/// | `AssetInstallationRequest.downloadAndInstall()` | `async throws` |
///
/// `SpeechTranscriber.Result.text` is an `AttributedString`, not a `String` — the attributes carry
/// confidence and timing. AURA wants the plain text, so it is extracted rather than interpolated, because
/// interpolating an `AttributedString` produces a description with markup in it.
///
/// ### Authorization
/// Both microphone **and** speech-recognition authorization are required; the new API did not remove the
/// `SFSpeechRecognizer` gate. Both usage descriptions are already declared in `project.yml`.
///
/// ### What is not verified, and cannot be here
/// This has never run against a microphone. CI compiles it and tests the pure parts; a simulator has no
/// real audio input and no eligible speech assets. In particular **the audio format handed to the analyzer
/// is the untested seam**: the tap is installed with the input node's own format, since `AVAudioEngine`
/// requires that, and if the analyzer rejects it on real hardware an `AVAudioConverter` step belongs in
/// `beginListening`. That is a known gap, written down rather than presented as working.
actor SystemSpeechRecognitionService: SpeechRecognitionService {

    private let permissions: any PermissionManaging
    private let audioEngine = AVAudioEngine()

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var isListening = false

    init(permissions: any PermissionManaging) {
        self.permissions = permissions
    }

    // MARK: - Availability

    func availability() async -> SpeechRecognitionAvailability {
        guard SpeechTranscriber.isAvailable else { return .unsupportedDevice }

        switch await permissions.status(for: .microphone) {
        case .notDetermined: return .microphonePermissionRequired
        case .denied, .restricted: return .microphoneDenied
        case .authorized, .limited: break
        }

        switch await permissions.status(for: .speechRecognition) {
        case .notDetermined: return .speechPermissionRequired
        case .denied, .restricted: return .speechDenied
        case .authorized, .limited: break
        }

        let locale = Locale.current
        guard let resolved = Self.bestSupportedLocale(for: locale, in: SpeechTranscriber.supportedLocales) else {
            return .unsupportedLocale(locale)
        }
        // Supported but not installed means the assets still have to come down, which is a visible wait
        // rather than a failure — `prepare(locale:)` is what resolves it.
        if Self.bestSupportedLocale(for: resolved, in: SpeechTranscriber.installedLocales) == nil {
            return .assetsDownloading
        }
        return .available
    }

    /// Picks the best supported locale for a request, preferring an exact match and falling back to language.
    ///
    /// `static` and pure so it is testable without a speech engine, which matters because the failure it
    /// prevents is silent: Apple mixes `en_US` and `en-US` between APIs, and a naive equality check reports
    /// a perfectly supported language as unsupported.
    static func bestSupportedLocale(for requested: Locale, in supported: [Locale]) -> Locale? {
        func normalized(_ identifier: String) -> String {
            identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        }
        func language(_ locale: Locale) -> String? {
            locale.language.languageCode?.identifier.lowercased()
        }

        let target = normalized(requested.identifier)
        if let exact = supported.first(where: { normalized($0.identifier) == target }) {
            return exact
        }

        guard let requestedLanguage = language(requested) else { return nil }

        // Same language, and prefer the same region when one is available — en-GB is a better answer for a
        // British user than en-US, even though either would work.
        let sameLanguage = supported.filter { language($0) == requestedLanguage }
        if let region = requested.region?.identifier.lowercased(),
           let regional = sameLanguage.first(where: { $0.region?.identifier.lowercased() == region }) {
            return regional
        }
        return sameLanguage.first
    }

    // MARK: - Preparation

    func prepare(locale: Locale) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw AuraError.speechRecognitionUnavailable(reason: "not supported on this device")
        }
        guard let resolved = Self.bestSupportedLocale(for: locale, in: SpeechTranscriber.supportedLocales) else {
            throw AuraError.speechRecognitionUnavailable(reason: "no support for \(locale.identifier)")
        }

        let module = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)

        // Reserving the locale is what keeps its assets from being reclaimed underneath a live session. The
        // device caps how many locales may be reserved, so a refusal is informative rather than fatal —
        // transcription still works, it is just competing for asset space.
        if try await AssetInventory.reserve(locale: resolved) == false {
            AuraLog.voice.notice("Could not reserve \(resolved.identifier, privacy: .public) for transcription.")
        }

        // `nil` means everything needed is already installed, which is the common case after first run.
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Listening

    /// `nonisolated` because the protocol requirement is synchronous, which an actor-isolated method cannot
    /// satisfy. It only builds the stream and hands the work back to the actor.
    nonisolated func startListening(
        locale: Locale
    ) throws -> AsyncThrowingStream<SpeechTranscriptionUpdate, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.beginListening(locale: locale, continuation: continuation)
                } catch is CancellationError {
                    await self.teardown()
                    continuation.finish(throwing: AuraError.cancelled)
                } catch {
                    await self.teardown()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                // Dropping the stream must stop the microphone. Leaving it open because a consumer stopped
                // reading is the one failure here a user would experience as a privacy breach.
                task.cancel()
                Task { await self.cancel() }
            }
        }
    }

    private func beginListening(
        locale: Locale,
        continuation: AsyncThrowingStream<SpeechTranscriptionUpdate, any Error>.Continuation
    ) async throws {
        let availability = await availability()
        if availability != .assetsDownloading, let error = availability.asError {
            throw error
        }

        guard !isListening else {
            throw AuraError.speechRecognitionUnavailable(reason: "already listening")
        }

        guard let resolved = Self.bestSupportedLocale(for: locale, in: SpeechTranscriber.supportedLocales) else {
            throw AuraError.speechRecognitionUnavailable(reason: "no support for \(locale.identifier)")
        }

        let module = SpeechTranscriber(locale: resolved, preset: .progressiveTranscription)
        let analyzer = SpeechAnalyzer(modules: [module], options: nil)
        self.transcriber = module
        self.analyzer = analyzer

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = inputContinuation

        // Results are consumed on their own task so audio keeps flowing while text is delivered. The
        // transcriber yields cumulative phrases with `isFinal` marking the ones it will not revise.
        resultsTask = Task { [weak self] in
            do {
                for try await result in module.results {
                    continuation.yield(
                        SpeechTranscriptionUpdate(
                            text: String(result.text.characters),
                            isFinal: result.isFinal
                        )
                    )
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            await self?.teardown()
        }

        try startAudioEngine(feeding: inputContinuation)
        isListening = true

        try await analyzer.start(inputSequence: inputStream)
    }

    /// Taps the microphone and forwards buffers to the analyzer.
    ///
    /// The tap format is the input node's own: `AVAudioEngine` requires the tap to match it, so the analyzer
    /// is asked to accept it rather than the other way round. See the note in the type's documentation about
    /// this being the untested seam.
    private func startAudioEngine(feeding continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopListening() async {
        guard isListening else { return }
        isListening = false

        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil

        // Finalises rather than cancels, so the transcriber emits its last `isFinal` result instead of
        // discarding a half-recognised sentence the user did say.
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            AuraLog.voice.error("Finalising transcription failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancel() async {
        guard isListening || analyzer != nil else { return }
        isListening = false

        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil

        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    private func teardown() async {
        isListening = false
        stopAudio()
        inputContinuation?.finish()
        inputContinuation = nil
        analyzer = nil
        transcriber = nil
        resultsTask = nil
    }

    /// Stops the engine and releases the session, so the microphone indicator goes away.
    private func stopAudio() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
