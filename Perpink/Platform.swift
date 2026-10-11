import SwiftUI

#if canImport(UIKit)
import UIKit

/// The platform's bitmap image: `UIImage` on iOS, `NSImage` on the Mac.
typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

extension Color {
    /// Fills that sit one and two steps above the window's background.
    static let raisedBackground = Color(.secondarySystemBackground)
    static let raisedBackground2 = Color(.tertiarySystemBackground)
}
#else
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

extension Color {
    // AppKit has no stacked system backgrounds; a translucent fill reads as
    // one level up over whatever is beneath, sidebar or window.
    static let raisedBackground = Color(.quaternarySystemFill)
    static let raisedBackground2 = Color(.tertiarySystemFill)
}
#endif
