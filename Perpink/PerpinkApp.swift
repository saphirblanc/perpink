import SwiftUI

@main
struct PerpinkApp: App {
    @State private var settings = SettingsStore()
    #if os(macOS)
    /// Owned here rather than by the window so the menu bar's commands reach it.
    @State private var viewModel = ChatViewModel()
    #endif

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            ChatView(settings: settings)
                .readingSize(step: settings.textSizeStep)
                .preferredColorScheme(.dark)
        }
        #else
        // One window: the run in flight is recorded on disk as the app's one
        // pending run, which two windows sending at once would trample.
        Window("Perpink", id: "main") {
            MacChatView(viewModel: viewModel, settings: settings)
                .readingSize(step: settings.textSizeStep)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            ChatCommands(viewModel: viewModel, settings: settings)
        }

        Settings {
            SettingsView(settings: settings)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
