import UIKit

/// Time to finish a request after the app leaves the screen (`beginBackgroundTask`). Ended once, by whoever is
/// first: the work, or the system running out of time.
@MainActor
package final class AppBackgroundTask {
    package var id: UIBackgroundTaskIdentifier = .invalid

    package init() {}

    /// Begun at once.
    package init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated { end() }
        }
    }

    package func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
