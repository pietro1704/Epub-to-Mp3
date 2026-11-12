import Foundation

/// The requested density is independent of the column count that currently fits.
struct LibraryColumnPreference {
    private let defaults: UserDefaults
    static let key = "library.requestedColumns.v1"
    static let choices = 1...8

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var requestedColumns: Int {
        get {
            guard defaults.object(forKey: Self.key) != nil else { return 2 }
            return min(Self.choices.upperBound, max(Self.choices.lowerBound, defaults.integer(forKey: Self.key)))
        }
        nonmutating set { defaults.set(min(8, max(1, newValue)), forKey: Self.key) }
    }
}
