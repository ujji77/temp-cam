import UIKit

/// Drives screen brightness to full while the front flash is on and restores the
/// user's brightness afterwards (including when the app goes to the background).
@MainActor
final class ScreenLight {
    private var savedBrightness: CGFloat?

    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
    }

    func setOn(_ on: Bool) {
        guard let screen else { return }
        if on {
            if savedBrightness == nil {
                savedBrightness = screen.brightness
            }
            screen.brightness = 1
        } else if let saved = savedBrightness {
            screen.brightness = saved
            savedBrightness = nil
        }
    }
}
