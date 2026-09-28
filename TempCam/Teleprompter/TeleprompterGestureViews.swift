import SwiftUI

/// Gesture tips laid out where the gestures happen: slower on the left half,
/// faster on the right, scrolling in the middle.
struct TeleprompterGestureHints: View {
    var onDismiss: () -> Void
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 14) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    zoneHint(
                        symbol: "tortoise.fill",
                        title: "Slower",
                        detail: "Double-tap left",
                        delay: 0.05
                    )
                    zoneHint(
                        symbol: "hare.fill",
                        title: "Faster",
                        detail: "Double-tap right",
                        delay: 0.12
                    )
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "hand.draw.fill")
                    .symbolEffect(.wiggle.up, options: .repeat(.periodic(delay: 1.2)), isActive: appeared)
                Text("Swipe up or down to scroll")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .glassEffect(.regular.tint(.black.opacity(0.25)), in: Capsule())
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .animation(.snappy(duration: 0.35).delay(0.2), value: appeared)
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .onAppear { appeared = true }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Dismisses tips")
    }

    private func zoneHint(symbol: String, title: String, detail: String, delay: Double) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(CameraChrome.accent)
                .symbolEffect(.bounce, options: .repeat(.periodic(2, delay: 1.4)), isActive: appeared)
            Text(title)
                .font(.system(size: 15, weight: .bold))
            HStack(spacing: 4) {
                Image(systemName: "hand.tap.fill")
                Text(detail)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.72))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(.black.opacity(0.25)), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared ? 1 : 0.92)
        .animation(.snappy(duration: 0.35).delay(delay), value: appeared)
    }
}

/// Reels-style feedback on the side of the screen that was double-tapped.
struct SpeedPulseView: View {
    var pulse: SpeedPulse

    private var faster: Bool { pulse.side == .trailing }

    var body: some View {
        // Overlays never contribute to layout, so the oversized glow can't widen the screen.
        Color.clear.overlay(alignment: faster ? .trailing : .leading) {
            VStack(spacing: 8) {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { index in
                        Image(systemName: faster ? "chevron.right" : "chevron.left")
                            .font(.system(size: 14, weight: .heavy))
                            .symbolEffect(
                                .variableColor.iterative,
                                options: .speed(2),
                                value: pulse.id
                            )
                            .opacity(chevronOpacity(index))
                    }
                }
                .environment(\.layoutDirection, .leftToRight)

                Image(systemName: faster ? "hare.fill" : "tortoise.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .symbolEffect(.bounce, value: pulse.id)

                Text(pulse.hitLimit ? (faster ? "Max" : "Min") : String(format: "%.1f×", pulse.speed))
                    .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText(value: pulse.speed))
            }
            .foregroundStyle(pulse.hitLimit ? CameraChrome.accent : .white)
            .frame(width: 86, height: 118)
            .glassEffect(.regular.tint(.black.opacity(0.22)), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.horizontal, 22)
            .background(alignment: faster ? .trailing : .leading) {
                // Soft glow hugging the tapped edge, like the seek ripple in Reels/YouTube.
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [.white.opacity(0.22), .white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: 220
                        )
                    )
                    .frame(width: 440, height: 560)
                    .offset(x: faster ? 220 : -220)
            }
        }
        .allowsHitTesting(false)
        .animation(.snappy(duration: 0.2), value: pulse)
        .accessibilityElement()
        .accessibilityLabel(pulse.hitLimit ? "Speed limit reached" : "Speed \(String(format: "%.1f", pulse.speed)) times")
    }

    /// Chevrons brighten toward the direction of change.
    private func chevronOpacity(_ index: Int) -> Double {
        let ordered = faster ? index : 2 - index
        return 0.45 + Double(ordered) * 0.27
    }
}
