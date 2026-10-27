import Foundation

enum PlayerDismissalDecision {
    static func shouldDismiss(translation: Double, velocity: Double, cancelled: Bool) -> Bool {
        guard !cancelled, translation.isFinite, velocity.isFinite else { return false }
        return translation > 120 || velocity > 800
    }
}
