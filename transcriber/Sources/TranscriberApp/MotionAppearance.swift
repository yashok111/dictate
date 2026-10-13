import SwiftUI

private struct GentleMotion<Value: Equatable>: ViewModifier {
    let value: Value
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: duration), value: value)
    }
}

private struct PlaybackSymbolMotion: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 14.0, *), !reduceMotion {
            content.contentTransition(.symbolEffect(.replace))
        } else {
            content
        }
    }
}

extension View {
    // Scope animation to a deliberate state change, never the whole transcript.
    func gentleMotion<Value: Equatable>(value: Value, duration: Double = 0.2) -> some View {
        modifier(GentleMotion(value: value, duration: duration))
    }

    func playbackSymbolMotion() -> some View {
        modifier(PlaybackSymbolMotion())
    }
}
