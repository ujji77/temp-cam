import SwiftUI

/// Bright edge light for the front camera. The screen is the only light source
/// facing the user, so this stands in for a flash while filming yourself.
struct FrontFlashRing: View {
    static let color = Color(red: 1, green: 0.97, blue: 0.92)
    var width: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size)
            Path { path in
                path.addRect(rect)
                path.addRoundedRect(
                    in: rect.insetBy(dx: width, dy: width),
                    cornerSize: CGSize(width: 34, height: 34),
                    style: .continuous
                )
            }
            .fill(Self.color, style: FillStyle(eoFill: true))

            // Inner glow. A `.shadow` on the ring would also fill the cutout.
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Self.color.opacity(0.8), lineWidth: 10)
                .blur(radius: 9)
                .padding(width)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Rule-of-thirds guide over the preview.
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for fraction in [1.0 / 3.0, 2.0 / 3.0] {
                    let x = geo.size.width * fraction
                    let y = geo.size.height * fraction
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.42), lineWidth: 0.75)
            .shadow(color: .black.opacity(0.35), radius: 0.5)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
