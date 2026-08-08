import AVFoundation
import Foundation
import Speech

/// The real `PermissionManaging`, backed by the system frameworks.
///
/// ### Scope, stated rather than implied
/// Only **microphone** and **speech recognition** are wired, because those are what Phase 5 needs. The rest
/// — calendar, reminders, contacts, location, notifications — report `.notDetermined`, which is literally
/// true: AURA has never asked, because the features that would ask do not exist yet.
///
/// That is deliberately the honest answer rather than a convenient one. `.notDetermined` is not usable, so
/// `ToolRegistry` filters out any tool needing an unwired permission, and the Privacy dashboard shows "Not
/// asked yet" instead of implying a grant AURA does not hold. Each phase that adds a capability wires its
/// own permission here; a `request` for an unwired one is a no-op rather than a prompt AURA cannot honour.
///
/// ### Why an actor
/// Nothing here holds mutable state, but the protocol is `Sendable` and the underlying APIs are a mix of
/// completion handlers and main-thread-sensitive calls. An actor gives one place where that is serialised.
actor SystemPermissionManager: PermissionManaging {

    // MARK: - Status

    func status(for permission: AuraPermission) async -> PermissionStatus {
        switch permission {
        case .microphone:
            return Self.microphoneStatus(AVAudioApplication.shared.recordPermission)
        case .speechRecognition:
            return Self.speechStatus(SFSpeechRecognizer.authorizationStatus())
        case .calendar, .reminders, .contacts, .location, .notifications:
            // Wired by the phase that introduces the feature needing it. Never reported as granted.
            return .notDetermined
        }
    }

    func allStatuses() async -> [AuraPermission: PermissionStatus] {
        var statuses: [AuraPermission: PermissionStatus] = [:]
        for permission in AuraPermission.allCases {
            statuses[permission] = await status(for: permission)
        }
        return statuses
    }

    func grantedPermissions() async -> Set<AuraPermission> {
        var granted: Set<AuraPermission> = []
        for permission in AuraPermission.allCases where await status(for: permission).isUsable {
            granted.insert(permission)
        }
        return granted
    }

    // MARK: - Requesting

    func request(_ permission: AuraPermission) async -> PermissionStatus {
        let current = await status(for: permission)

        // iOS shows nothing the second time, so re-requesting a denied permission would appear to hang.
        // The caller sends the user to Settings instead.
        guard current == .notDetermined else { return current }

        switch permission {
        case .microphone:
            let granted = await Self.requestMicrophone()
            return granted ? .authorized : .denied
        case .speechRecognition:
            return Self.speechStatus(await Self.requestSpeechRecognition())
        case .calendar, .reminders, .contacts, .location, .notifications:
            // No prompt, because there is nothing behind it yet. Prompting for access AURA cannot use would
            // spend the one chance iOS gives to ask.
            AuraLog.permissions.notice(
                "Ignored a request for \(permission.rawValue, privacy: .public): not wired up yet."
            )
            return .notDetermined
        }
    }

    // MARK: - Mapping

    /// Maps `AVAudioApplication.recordPermission` onto AURA's status.
    ///
    /// `static` and pure so the mapping is testable without a microphone. `@unknown default` is required
    /// because the enum is not frozen — a new case must degrade to "never asked" rather than being
    /// mis-reported as granted.
    static func microphoneStatus(_ permission: AVAudioApplication.recordPermission) -> PermissionStatus {
        switch permission {
        case .granted: return .authorized
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Maps `SFSpeechRecognizerAuthorizationStatus` onto AURA's status.
    static func speechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Bridging the callback APIs

    /// Both request APIs are completion-handler based, and both call back on an arbitrary queue.
    /// `withCheckedContinuation` is what makes them awaitable exactly once.
    private static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func requestSpeechRecognition() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
