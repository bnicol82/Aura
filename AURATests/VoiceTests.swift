import AVFoundation
import Foundation
import Speech
import Testing

@testable import AURA

/// What can be tested about voice without a microphone or an eligible device.
///
/// Recognition and synthesis themselves need real audio hardware, so they are not tested here. Everything
/// *around* them — locale resolution, rate mapping, voice mapping, authorization translation — is pure, and
/// those are the parts that fail silently rather than loudly.
@Suite("Voice")
struct VoiceTests {

    // MARK: Locale resolution

    @Test("An exact locale match wins, whichever separator style each side uses")
    func resolvesExactLocale() throws {
        // Apple mixes `en_US` and `en-US` between APIs. A naive equality check reports a perfectly
        // supported language as unsupported, and the user is told AURA cannot understand their language.
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        let resolved = try #require(
            SystemSpeechRecognitionService.bestSupportedLocale(
                for: Locale(identifier: "en_US"), in: supported
            )
        )
        #expect(resolved.identifier == "en-US")
    }

    @Test("A different region falls back to the same language rather than to nothing")
    func fallsBackToLanguage() throws {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "de-DE")]
        let resolved = try #require(
            SystemSpeechRecognitionService.bestSupportedLocale(
                for: Locale(identifier: "en-AU"), in: supported
            )
        )
        // en-AU is not offered, but transcribing Australian English with a US model is enormously better
        // than refusing to listen.
        #expect(resolved.identifier == "en-US")
    }

    @Test("When several regions share the language, the requested region is preferred")
    func prefersMatchingRegion() throws {
        let supported = [
            Locale(identifier: "en-US"),
            Locale(identifier: "en-GB"),
            Locale(identifier: "en-AU")
        ]
        let resolved = try #require(
            SystemSpeechRecognitionService.bestSupportedLocale(
                for: Locale(identifier: "en-GB"), in: supported
            )
        )
        #expect(resolved.identifier == "en-GB")
    }

    @Test("An unsupported language resolves to nothing rather than to a wrong language")
    func refusesUnsupportedLanguage() {
        let supported = [Locale(identifier: "en-US"), Locale(identifier: "fr-FR")]
        // Silently transcribing Japanese with a French model would produce confident nonsense, which is
        // worse than saying the language is not supported.
        #expect(
            SystemSpeechRecognitionService.bestSupportedLocale(
                for: Locale(identifier: "ja-JP"), in: supported
            ) == nil
        )
        #expect(
            SystemSpeechRecognitionService.bestSupportedLocale(
                for: Locale(identifier: "en-US"), in: []
            ) == nil
        )
    }

    // MARK: Speech rate

    @Test("Rate 0.5 is the system default, not the midpoint of the extremes")
    func mapsRateToSystemDefault() {
        // The midpoint of minimum and maximum is audibly faster than what iOS calls normal, so a naive
        // linear mapping makes the assistant sound rushed at what the UI labels "normal".
        #expect(SystemSpeechSynthesisService.utteranceRate(from: 0.5) == AVSpeechUtteranceDefaultSpeechRate)
    }

    @Test("Rate is monotonic across its range and clamped at both ends")
    func mapsRateMonotonically() {
        let slowest = SystemSpeechSynthesisService.utteranceRate(from: 0)
        let slow = SystemSpeechSynthesisService.utteranceRate(from: 0.25)
        let normal = SystemSpeechSynthesisService.utteranceRate(from: 0.5)
        let fast = SystemSpeechSynthesisService.utteranceRate(from: 0.75)
        let fastest = SystemSpeechSynthesisService.utteranceRate(from: 1)

        #expect(slowest < slow)
        #expect(slow < normal)
        #expect(normal < fast)
        #expect(fast < fastest)

        #expect(slowest == AVSpeechUtteranceMinimumSpeechRate)
        #expect(fastest == AVSpeechUtteranceMaximumSpeechRate)

        // Out-of-range input clamps rather than producing a rate the synthesizer would reject.
        #expect(SystemSpeechSynthesisService.utteranceRate(from: -3) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(SystemSpeechSynthesisService.utteranceRate(from: 9) == AVSpeechUtteranceMaximumSpeechRate)
    }

    // MARK: Voice language matching

    @Test("Language matching ignores region and separator style")
    func matchesLanguagesLoosely() {
        #expect(SystemSpeechSynthesisService.languagesMatch("en-US", "en_GB"))
        #expect(SystemSpeechSynthesisService.languagesMatch("en_US", "en-US"))
        #expect(!SystemSpeechSynthesisService.languagesMatch("en-US", "fr-FR"))
        // An empty identifier must not match everything, which is what a naive prefix comparison would do.
        #expect(!SystemSpeechSynthesisService.languagesMatch("", "en-US"))
        #expect(!SystemSpeechSynthesisService.languagesMatch("", ""))
    }

    // MARK: Permission mapping

    @Test("Microphone permission states map onto AURA's, and unknown ones are not granted")
    func mapsMicrophonePermission() {
        #expect(SystemPermissionManager.microphoneStatus(.granted) == .authorized)
        #expect(SystemPermissionManager.microphoneStatus(.denied) == .denied)
        #expect(SystemPermissionManager.microphoneStatus(.undetermined) == .notDetermined)
    }

    @Test("Speech authorization states map onto AURA's, including restricted")
    func mapsSpeechAuthorization() {
        #expect(SystemPermissionManager.speechStatus(.authorized) == .authorized)
        #expect(SystemPermissionManager.speechStatus(.denied) == .denied)
        // Restricted is not the same as denied: asking again will not help, so the UI must not offer to.
        #expect(SystemPermissionManager.speechStatus(.restricted) == .restricted)
        #expect(SystemPermissionManager.speechStatus(.notDetermined) == .notDetermined)
    }

    @Test("Only granted and limited count as usable")
    func onlyUsableStatusesAreUsable() {
        // What `ToolRegistry` filters on, so a mistake here would hand a capability to a tool the user
        // never authorised.
        #expect(PermissionStatus.authorized.isUsable)
        #expect(PermissionStatus.limited.isUsable)
        #expect(!PermissionStatus.notDetermined.isUsable)
        #expect(!PermissionStatus.denied.isUsable)
        #expect(!PermissionStatus.restricted.isUsable)
    }

    @Test("Unwired permissions report not-asked and never appear as granted")
    func unwiredPermissionsAreNotGranted() async {
        let manager = SystemPermissionManager()

        // Reported honestly rather than conveniently: AURA has not asked, because the features that would
        // ask do not exist yet. Anything else would imply access it does not hold.
        for permission in [AuraPermission.calendar, .reminders, .contacts, .location, .notifications] {
            #expect(await manager.status(for: permission) == .notDetermined)
            // Requesting is a no-op rather than a prompt AURA could not honour.
            #expect(await manager.request(permission) == .notDetermined)
        }

        let granted = await manager.grantedPermissions()
        #expect(!granted.contains(.calendar))
        #expect(!granted.contains(.reminders))
        #expect(!granted.contains(.contacts))
        #expect(!granted.contains(.location))
        #expect(!granted.contains(.notifications))
    }

    @Test("Every permission appears in the dashboard's statuses")
    func allStatusesCoversEveryPermission() async {
        // The Privacy dashboard renders from this, so a missing key is a permission the user cannot see.
        let statuses = await SystemPermissionManager().allStatuses()
        #expect(statuses.count == AuraPermission.allCases.count)
        for permission in AuraPermission.allCases {
            #expect(statuses[permission] != nil)
        }
    }

    // MARK: Availability messages

    @Test("Every unavailability reason has both a sentence and an error")
    func availabilityReasonsAreComplete() {
        let reasons: [SpeechRecognitionAvailability] = [
            .microphonePermissionRequired,
            .speechPermissionRequired,
            .microphoneDenied,
            .speechDenied,
            .unsupportedDevice,
            .unsupportedLocale(Locale(identifier: "ja-JP")),
            .assetsDownloading,
            .temporarilyUnavailable(reason: "busy")
        ]

        for reason in reasons {
            #expect(!reason.isAvailable)
            #expect(!reason.userFacingDescription.isEmpty)
            // Every reason has to translate into an error, or attempting to listen anyway would fail with
            // nothing to tell the user.
            #expect(reason.asError != nil)
        }

        #expect(SpeechRecognitionAvailability.available.isAvailable)
        #expect(SpeechRecognitionAvailability.available.asError == nil)
    }
}
