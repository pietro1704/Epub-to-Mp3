import Foundation

/// Repeated observations must not invalidate a pending visual completion.
struct VisibilityTransition {
    struct Request: Equatable {
        let generation: UInt64
        let visible: Bool
    }
    private(set) var requestedVisibility: Bool?
    private var generation: UInt64 = 0

    mutating func request(visible: Bool) -> Request? {
        guard requestedVisibility != visible else { return nil }
        generation &+= 1
        requestedVisibility = visible
        return Request(generation: generation, visible: visible)
    }

    func isCurrent(_ request: Request) -> Bool {
        request.generation == generation && request.visible == requestedVisibility
    }

    mutating func invalidate(keeping visibility: Bool?) {
        generation &+= 1
        requestedVisibility = visibility
    }
}
