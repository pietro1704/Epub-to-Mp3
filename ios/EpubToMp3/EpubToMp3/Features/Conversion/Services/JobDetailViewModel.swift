import Combine
import Foundation

/// Presents the completed local snapshot produced by an embedded Rust
/// conversion. Apple clients never stream jobs from a remote backend.
@MainActor
final class JobDetailViewModel: ObservableObject {
    @Published private(set) var snapshot: JobSnapshot?

    /// Delivers every presented snapshot to the owning screen so a player that
    /// is already attached to this job can adopt the completed chapter list
    /// without coupling this view model to UIKit or AppKit.
    var onSnapshot: ((JobSnapshot) -> Void)?

    func showLocalSnapshot(_ snapshot: JobSnapshot) {
        self.snapshot = snapshot
        onSnapshot?(snapshot)
    }
}
