import UIKit

/// Bridges the URLSession background-session events (model downloads) to
/// the SwiftUI app lifecycle.
///
/// When the system relaunches the app in the background to deliver a
/// finished download (the app was terminated mid-transfer), it hands the
/// app a completion handler here. `BackgroundDownloadManager` stores it
/// and releases it from `urlSessionDidFinishEvents` once every event has
/// been processed, so iOS can suspend the app again cleanly without
/// killing a transfer mid-finalization.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier == BackgroundDownloadManager.sessionIdentifier {
            BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
}
