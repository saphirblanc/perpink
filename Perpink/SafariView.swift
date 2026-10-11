import SwiftUI

#if os(iOS)
import SafariServices

/// Opens a source inside the app. Handing every citation to Safari loses the
/// thread you were reading; this keeps it one swipe behind the page.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url, configuration: SFSafariViewController.Configuration())
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A URL in the shape `.sheet(item:)` wants.
struct WebLink: Identifiable {
    let url: URL

    var id: String { url.absoluteString }
}
#endif
