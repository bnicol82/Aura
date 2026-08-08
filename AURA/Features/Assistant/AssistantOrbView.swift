import SwiftUI

/// The assistant's presence on screen (§42).
///
/// One view renders all six voice states, because the orb is how the user knows what AURA is doing
/// without reading anything. Two accessibility requirements are treated as requirements rather than
/// polish: every state is distinguishable **without** motion (Reduce Motion turns animation off and
/// the states still differ by colour and ring weight), and the whole thing is one accessibility
/// element with a spoken label instead of decorative layers VoiceOver would enumerate.
@MainActor
struct AssistantOrbView: View {
    var state: VoiceState
    /// Live input level, 0...1, used to make listening feel responsive. Ignored under Reduce Motion.
    var audioLevel: Double = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var isAnimating = false

    var body: some View {
        ZStack {
            outerGlow
            rotatingRing
            core
        }
        .compositingGroup()
        .animation(.easeInOut(duration: 0.35), value: state)
        // `task` rather than `onAppear`: the repeating animations below are installed against this
        // view's geometry, and starting them in `onAppear` races the first layout pass. On the
        // onboarding welcome screen — the one place nothing forces a second layout — that race left the
        // ring visibly off-centre from the core. See docs/BUILD_LOG.md.
        .task {
            guard !reduceMotion else { return }
            isAnimating = true
        }
        .onChange(of: reduceMotion) { _, newValue in
            isAnimating = !newValue
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant")
        .accessibilityValue(state.accessibilityAnnouncement)
    }

    // MARK: - Layers

    private var outerGlow: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [palette.primary.opacity(0.35), palette.primary.opacity(0)],
                    center: .center,
                    startRadius: 4,
                    endRadius: 130
                )
            )
            // Anchors are stated explicitly throughout this view. The default is already `.center`, but
            // an implicit anchor is resolved from the layer's geometry, and every layer here has to
            // agree on one centre or the orb comes apart.
            .scaleEffect(glowScale, anchor: .center)
            .animation(breathingAnimation, value: isAnimating)
            .blur(radius: 12)
    }

    private var rotatingRing: some View {
        Circle()
            .strokeBorder(
                AngularGradient(
                    colors: [
                        palette.primary.opacity(0.15),
                        palette.secondary,
                        palette.primary,
                        palette.primary.opacity(0.15)
                    ],
                    center: .center
                ),
                lineWidth: ringWidth
            )
            .rotationEffect(.degrees(isAnimating ? 360 : 0), anchor: .center)
            .animation(rotationAnimation, value: isAnimating)
            .padding(6)
    }

    private var core: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        palette.secondary.opacity(colorScheme == .dark ? 0.55 : 0.4),
                        palette.primary.opacity(0.12)
                    ],
                    center: UnitPoint(x: 0.38, y: 0.32),
                    startRadius: 2,
                    endRadius: 90
                )
            )
            .overlay {
                if case .toolExecution = state {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(palette.primary)
                        .transition(.scale.combined(with: .opacity))
                } else if case .error = state {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(palette.primary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .scaleEffect(coreScale, anchor: .center)
            .animation(breathingAnimation, value: isAnimating)
            .padding(22)
    }

    // MARK: - Appearance per state

    private struct Palette {
        var primary: Color
        var secondary: Color
    }

    private var palette: Palette {
        switch state {
        case .idle:
            return Palette(primary: .accentColor, secondary: .accentColor.opacity(0.6))
        case .listening:
            return Palette(primary: Color(red: 0.29, green: 0.64, blue: 0.98), secondary: .cyan)
        case .processing:
            return Palette(primary: Color(red: 0.55, green: 0.45, blue: 0.98), secondary: .indigo)
        case .toolExecution:
            return Palette(primary: Color(red: 0.98, green: 0.68, blue: 0.28), secondary: .orange)
        case .speaking:
            return Palette(primary: Color(red: 0.30, green: 0.80, blue: 0.62), secondary: .mint)
        case .error:
            return Palette(primary: Color(red: 0.94, green: 0.36, blue: 0.36), secondary: .red)
        }
    }

    /// Ring weight also encodes state, so the orb reads correctly in greyscale and with animation off.
    private var ringWidth: CGFloat {
        switch state {
        case .idle: return 2
        case .listening: return 4 + CGFloat(audioLevel.clamped(to: 0...1)) * 5
        case .processing: return 5
        case .toolExecution: return 4
        case .speaking: return 6
        case .error: return 3
        }
    }

    private var glowScale: CGFloat {
        guard isAnimating else { return 1 }
        switch state {
        case .idle: return 1.04
        case .listening: return 1.10 + CGFloat(audioLevel.clamped(to: 0...1)) * 0.12
        case .processing: return 1.08
        case .toolExecution: return 1.06
        case .speaking: return 1.14
        case .error: return 1
        }
    }

    private var coreScale: CGFloat {
        guard isAnimating else { return 1 }
        switch state {
        case .idle: return 1.02
        case .listening: return 1.05
        case .processing: return 1.04
        case .toolExecution: return 1.02
        case .speaking: return 1.07
        case .error: return 1
        }
    }

    // MARK: - Motion

    private var rotationAnimation: Animation? {
        guard isAnimating else { return nil }
        let duration: Double
        switch state {
        case .idle: duration = 24
        case .listening: duration = 10
        case .processing: duration = 4
        case .toolExecution: duration = 6
        case .speaking: duration = 8
        case .error: duration = 0
        }
        guard duration > 0 else { return nil }
        return .linear(duration: duration).repeatForever(autoreverses: false)
    }

    private var breathingAnimation: Animation? {
        guard isAnimating else { return nil }
        if case .error = state { return nil }
        return .easeInOut(duration: state.isBusy ? 1.1 : 2.6).repeatForever(autoreverses: true)
    }
}

/// A labelled orb state for the preview gallery. A named type because `ForEach` needs an identity,
/// and Swift has no key paths into tuple elements.
private struct OrbPreviewCase: Identifiable {
    let label: String
    let state: VoiceState

    var id: String { label }
}

private let orbPreviewCases: [OrbPreviewCase] = [
    OrbPreviewCase(label: "Idle", state: .idle),
    OrbPreviewCase(label: "Listening", state: .listening(transcript: "what's on my schedule")),
    OrbPreviewCase(label: "Thinking", state: .processing),
    OrbPreviewCase(label: "Running a tool", state: .toolExecution(label: "Checking your calendar")),
    OrbPreviewCase(label: "Speaking", state: .speaking),
    OrbPreviewCase(label: "Error", state: .error(.noInternetConnection))
]

#Preview("Orb states") {
    ScrollView {
        VStack(spacing: 28) {
            ForEach(orbPreviewCases) { entry in
                VStack(spacing: 8) {
                    AssistantOrbView(state: entry.state, audioLevel: 0.6)
                        .frame(width: 150, height: 150)
                    Text(entry.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }
}
