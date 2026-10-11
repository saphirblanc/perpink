import PhotosUI
import SwiftUI

#if os(iOS)
struct ChatView: View {
    let settings: SettingsStore

    @State private var viewModel = ChatViewModel()
    @State private var showSettings = false
    @State private var showHistory = false
    @State private var webLink: WebLink?
    @State private var settingsIdentityOnOpen = ""
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            messageList
                .safeAreaInset(edge: .bottom) {
                    Composer(viewModel: viewModel, settings: settings, focused: $composerFocused) {
                        Button {
                            showPhotoPicker = true
                        } label: {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        if CameraPicker.isAvailable {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                        }
                    }
                }
                .navigationTitle("Perpink")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showHistory = true
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .disabled(!settings.isConfigured)
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            viewModel.newChat()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        .disabled(viewModel.messages.isEmpty)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings, onDismiss: {
                    // Another server, profile or key is another history.
                    if connectionIdentity != settingsIdentityOnOpen {
                        viewModel.newChat()
                        Task { await viewModel.refreshSessions(settings: settings) }
                    }
                }) {
                    SettingsView(settings: settings)
                        .onAppear { settingsIdentityOnOpen = connectionIdentity }
                }
                .sheet(isPresented: $showHistory) {
                    HistoryView(viewModel: viewModel, settings: settings)
                }
                .photosPicker(
                    isPresented: $showPhotoPicker,
                    selection: $pickedPhotos,
                    maxSelectionCount: max(1, viewModel.remainingPhotoSlots),
                    matching: .images
                )
                .onChange(of: pickedPhotos) { _, items in
                    guard !items.isEmpty else { return }
                    pickedPhotos = []
                    viewModel.attach(items.map { item in
                        { @Sendable in
                            guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
                            return PhotoAttachment.prepare(data)
                        }
                    })
                }
                .fullScreenCover(isPresented: $showCamera) {
                    CameraPicker { image in
                        viewModel.attach([{ @Sendable in PhotoAttachment.prepare(image) }])
                    }
                    .ignoresSafeArea()
                }
                .sheet(item: $webLink) { link in
                    SafariView(url: link.url).ignoresSafeArea()
                }
                // One place every link in the thread goes through.
                .environment(\.openURL, OpenURLAction { url in
                    guard url.scheme == "http" || url.scheme == "https" else {
                        return .systemAction
                    }
                    webLink = WebLink(url: url)
                    return .handled
                })
                // A copy made while the app is on screen is a passage the
                // user has in hand: offer it back as a follow-up to ask about.
                .onReceive(Clipboard.changes) {
                    guard scenePhase == .active,
                          let passage = Clipboard.copiedSelection(in: viewModel.messages)
                    else { return }
                    viewModel.quote = passage
                }
                .task {
                    viewModel.resumeIfNeeded(settings: settings)
                    await viewModel.refreshSessions(settings: settings)
                    #if DEBUG
                    openScreenshotScene()
                    #endif
                }
                // A run outlives leaving the app: Hermes keeps working on it,
                // and it is picked up again on the way back in. `.inactive` is
                // deliberately not handled — it fires for app-switcher peeks
                // and notification banners that never actually suspend us.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        Clipboard.ignoreCurrentContents()
                        viewModel.enteredForeground(settings: settings)
                    case .background:
                        viewModel.enteredBackground()
                    default:
                        break
                    }
                }
        }
    }

    // MARK: - Messages

    private var messageList: some View {
        MessageList(viewModel: viewModel, settings: settings) {
            emptyState
        }
        .scrollDismissesKeyboard(.interactively)
        // Tapping the message area dismisses the keyboard. Simultaneous so
        // buttons inside rows (copy, approvals) still receive their taps.
        .simultaneousGesture(
            TapGesture().onEnded { composerFocused = false }
        )
        // Swiping in from the left edge opens history, mirroring the
        // toolbar button. The recognizer lives on a strip at the edge
        // rather than on the whole list: spanning the messages, it also
        // claimed the drag that extends a text selection, and UIKit never
        // brought the Copy menu back. Simultaneous so the strip scrolls.
        .overlay(alignment: .leading) {
            Color.clear
                .frame(width: 24)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                            if value.translation.width > 80,
                               isHorizontal,
                               settings.isConfigured {
                                showHistory = true
                            }
                        }
                )
        }
    }

    /// Server, profile and key together: changing any of them in Settings
    /// points the app at a different history.
    private var connectionIdentity: String {
        "\(settings.baseURL.absoluteString)|\(settings.apiKey)"
    }

    #if DEBUG
    /// For App Store screenshots, from launch arguments: `-ScreenshotSession <id>`
    /// opens that conversation, `-ScreenshotHistory YES` the history and
    /// `-ScreenshotSettings YES` the settings.
    private func openScreenshotScene() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "ScreenshotSession"),
           let session = viewModel.sessions.first(where: { $0.id == id }) {
            viewModel.open(session, settings: settings)
        }
        if defaults.bool(forKey: "ScreenshotHistory") { showHistory = true }
        if defaults.bool(forKey: "ScreenshotSettings") { showSettings = true }
    }
    #endif

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Think in pink")
                .font(.title2.bold())
            if !settings.isConfigured {
                Text("Open Settings to point Perpink at your Hermes server.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

// MARK: - History

struct HistoryView: View {
    let viewModel: ChatViewModel
    let settings: SettingsStore

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    /// Filters on the title and on the opening of the first message.
    private var results: [HermesSession] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return viewModel.sessions }
        return viewModel.sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(term)
                || (session.preview ?? "").localizedCaseInsensitiveContains(term)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(results) { session in
                    Button {
                        viewModel.open(session, settings: settings)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.displayTitle)
                                .lineLimit(2)
                            Text(session.lastActivity, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(
                        session.id == viewModel.sessionID
                            ? Color.accentColor.opacity(0.15)
                            : nil
                    )
                }
                .onDelete { offsets in
                    let deleted = offsets.map { results[$0] }
                    Task {
                        for session in deleted {
                            await viewModel.delete(session, settings: settings)
                        }
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search conversations"
            )
            .refreshable {
                await viewModel.refreshSessions(settings: settings)
            }
            .task {
                await viewModel.refreshSessions(settings: settings)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if let error = viewModel.sessionsError, viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "Couldn't load history",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error)
                    )
                } else if viewModel.sessions.isEmpty {
                    ContentUnavailableView(
                        "No conversations yet",
                        systemImage: "clock.arrow.circlepath"
                    )
                } else if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
    }
}
#endif
