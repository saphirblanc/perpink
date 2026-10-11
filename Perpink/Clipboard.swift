import Combine
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The clipboard, as the way into a follow-up.
///
/// The system builds the selection menu for `Text` itself and leaves an app no
/// room for an item of its own, so a passage is picked up through the Copy the
/// user already reaches for: a change to the clipboard while the app is on
/// screen can only be this app's, and one that matches a message in the thread
/// is a passage to ask about. Reading it back is therefore always a read of our
/// own copy, which never raises the system's paste prompt.
@MainActor
enum Clipboard {
    /// The longest passage worth quoting. Past this, a selection is less a
    /// passage to ask about than the whole answer taken elsewhere.
    private static let maxLength = 2000

    /// How much a selection has to have, in letters and digits, before it is
    /// taken for a passage rather than a word grabbed in passing.
    private static let minFingerprint = 12

    /// The clipboard as this app last set it on purpose, which is a copy to
    /// take elsewhere rather than a passage to follow up on.
    private static var ownedChangeCount: Int?

    /// Takes whatever is on the clipboard for something from elsewhere.
    ///
    /// Called when the app comes back on screen: anything copied while it was
    /// away came from another app, and reading that is the one case iOS stops
    /// to ask the user about.
    static func ignoreCurrentContents() {
        ownedChangeCount = changeCount
    }

    /// Copies text as an explicit Copy button does: no follow-up offered.
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        ownedChangeCount = changeCount
    }

    /// Fires when the clipboard's contents change, from any app.
    ///
    /// iOS announces it; AppKit doesn't, so on the Mac the change count is
    /// sampled instead — a cheap read that never touches the contents.
    static var changes: AnyPublisher<Void, Never> {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)
            .map { _ in }
            .eraseToAnyPublisher()
        #else
        Timer.publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .map { _ in NSPasteboard.general.changeCount }
            .removeDuplicates()
            .dropFirst()
            .map { _ in }
            .eraseToAnyPublisher()
        #endif
    }

    /// The text just copied, if it is a selection out of one of `messages`.
    ///
    /// A copy is offered once: the clipboard still holds it after the
    /// question about it has gone out, and a later change notification for
    /// the same contents must not bring the quote back.
    static func copiedSelection(in messages: [ChatMessage]) -> String? {
        guard changeCount != ownedChangeCount,
              let copied = string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !copied.isEmpty, copied.count <= maxLength
        else { return nil }

        // Compared on letters and digits alone: what a selection yields is the
        // rendered answer, which has lost the Markdown the message still holds.
        let needle = fingerprint(copied)
        guard needle.count >= minFingerprint,
              messages.contains(where: { fingerprint($0.text).contains(needle) })
        else { return nil }
        ownedChangeCount = changeCount
        return copied
    }

    private static var changeCount: Int {
        #if canImport(UIKit)
        UIPasteboard.general.changeCount
        #else
        NSPasteboard.general.changeCount
        #endif
    }

    private static var string: String? {
        #if canImport(UIKit)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }

    private static func fingerprint(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
