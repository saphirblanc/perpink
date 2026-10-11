import SwiftUI

#if os(iOS)
/// Asks iOS to keep the app running after it leaves the foreground, so a search
/// in flight keeps streaming instead of being frozen mid-answer.
///
/// The reprieve is finite — tens of seconds, at the system's discretion — so it
/// covers stepping out of the app for a moment, not a long absence. When it runs
/// out the connection dies like any other; `PendingSearch` is what gets the
/// search going again on the way back in.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    /// Nested calls are ignored: the assertion is held until `end()`, which
    /// keeps a search that resumes into a second attempt covered throughout.
    func begin(name: String) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Expiry: hand the time back before iOS takes it, or it kills us.
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#else
/// A Mac app is never suspended, but App Nap throttles one whose window is
/// hidden or covered: this keeps a run's stream flowing at full speed while
/// the window is out of sight.
@MainActor
final class BackgroundActivity {
    private var activity: NSObjectProtocol?

    /// Nested calls are ignored, as on iOS.
    func begin(name: String) {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: name)
    }

    func end() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }
}
#endif
