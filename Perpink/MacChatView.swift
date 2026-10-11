#if os(macOS)
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The Mac window: Hermes's sessions in a sidebar that stays put, where the
/// iPhone keeps them in a sheet, and the thread beside them.
struct MacChatView: View {
    let viewModel: ChatViewModel
    let settings: SettingsStore

    @State private var query = ""
    /// Bumped by ⌘F: each request puts the cursor in the sidebar's search.
    @State private var searchRequests = 0
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    /// The server, profile and key the sidebar was last loaded for.
    @State private var loadedIdentity: String?
    @FocusState private var composerFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SessionSidebar(viewModel: viewModel, settings: settings, query: $query, searchRequests: searchRequests)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            thread
        }
        .frame(minWidth: 760, minHeight: 520)
        .focusedSceneValue(\.searchConversations, searchConversations)
        .task {
            loadedIdentity = connectionIdentity
            viewModel.resumeIfNeeded(settings: settings)
            guard settings.isConfigured else { return }
            async let sessions: Void = viewModel.refreshSessions(settings: settings)
            async let connection: Void = settings.checkConnection()
            _ = await (sessions, connection)
            #if DEBUG
            // For App Store screenshots: `-ScreenshotSession <id>` opens that conversation.
            if let id = UserDefaults.standard.string(forKey: "ScreenshotSession"),
               let session = viewModel.sessions.first(where: { $0.id == id }) {
                viewModel.open(session, settings: settings)
            }
            #endif
        }
        // There is no sheet to close behind Settings: another server, profile
        // or key is picked up once typing in the Settings window pauses.
        .task(id: connectionIdentity) {
            guard let loadedIdentity, loadedIdentity != connectionIdentity else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self.loadedIdentity = connectionIdentity
            viewModel.newChat()
            await viewModel.refreshSessions(settings: settings)
            if settings.isConfigured { await settings.checkConnection() }
        }
        // A run that just started has made its session; one that just ended
        // has likely been given a title. Either way the sidebar is behind.
        .onChange(of: viewModel.isSending) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                await viewModel.refreshSessions(settings: settings)
            }
        }
        // A copy made in this window is a passage the user has in hand:
        // offer it back as a follow-up to ask about.
        .onReceive(Clipboard.changes) {
            guard scenePhase == .active,
                  let passage = Clipboard.copiedSelection(in: viewModel.messages)
            else { return }
            viewModel.quote = passage
        }
        // A Mac app isn't suspended, so there is no going to the background
        // to handle; coming back is still the moment to set aside what was
        // copied elsewhere, and to pick up a run a sleeping Mac cut off.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Clipboard.ignoreCurrentContents()
                viewModel.enteredForeground(settings: settings)
            }
        }
    }

    // MARK: - Thread

    private var thread: some View {
        MessageList(viewModel: viewModel, settings: settings, maxWidth: readableColumnWidth) {
            emptyState
        }
        .safeAreaInset(edge: .bottom) {
            Composer(viewModel: viewModel, settings: settings, focused: $composerFocused) {
                Button("Choose Photo…") { showPhotoPicker = true }
                Button("Choose File…") { showFileImporter = true }
            }
        }
        .defaultFocus($composerFocused, true)
        .focusedSceneValue(\.startNewChat, startNewChat)
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: startNewChat) {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")
                .disabled(viewModel.messages.isEmpty)
            }
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
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            attachFiles(urls)
        }
        // Photos dragged in from Finder, Photos or a browser.
        .dropDestination(for: Data.self) { items, _ in
            guard viewModel.remainingPhotoSlots > 0, !viewModel.isSending else { return false }
            viewModel.attach(items.map { data in { @Sendable in PhotoAttachment.prepare(data) } })
            return true
        }
    }

    /// A new chat is one to type into: the cursor goes to the composer, from
    /// the sidebar or its search field too. Already on a new chat, that is
    /// all ⌘N does.
    private func startNewChat() {
        if !viewModel.messages.isEmpty {
            viewModel.newChat()
        }
        composerFocused = true
    }

    /// Puts the cursor in the sidebar's search field, bringing the sidebar
    /// back first if it was hidden.
    private func searchConversations() {
        columnVisibility = .all
        searchRequests += 1
    }

    /// The session's title, so the window says which conversation it holds.
    private var title: String {
        guard let id = viewModel.sessionID,
              let session = viewModel.sessions.first(where: { $0.id == id })
        else { return "Perpink" }
        return session.displayTitle
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Think in pink")
                .font(.title.bold())
            if !settings.isConfigured {
                SettingsLink {
                    Text("Open Settings to point Perpink at your Hermes server.")
                }
                .buttonStyle(.link)
            }
        }
        .padding()
        .offset(y: -45)
    }

    /// Files from the open panel sit outside the sandbox: each is read inside
    /// the access its URL was granted.
    private func attachFiles(_ urls: [URL]) {
        viewModel.attach(urls.map { url in
            { @Sendable in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return (try? Data(contentsOf: url)).flatMap(PhotoAttachment.prepare)
            }
        })
    }

    /// Server, profile and key together: changing any of them points the
    /// app at a different history.
    private var connectionIdentity: String {
        "\(settings.baseURL.absoluteString)|\(settings.apiKey)"
    }
}

// MARK: - Sidebar

/// Hermes's sessions, newest first, grouped by when they were last active.
private struct SessionSidebar: View {
    let viewModel: ChatViewModel
    let settings: SettingsStore
    @Binding var query: String
    let searchRequests: Int

    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        List(selection: selection) {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sessions) { session in
                        row(session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Delete", role: .destructive) {
                                    Task { await viewModel.delete(session, settings: settings) }
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, isPresented: $isSearching, placement: .sidebar, prompt: "Search conversations")
        .searchFocus($searchFocused)
        .onChange(of: searchRequests) {
            if #available(macOS 15, *) {
                searchFocused = true
            } else {
                // Before searchFocused, raising the presentation flag is the
                // only way in, and it moves the cursor only when it changes:
                // a field already presented is dropped first, a turn earlier.
                isSearching = false
                DispatchQueue.main.async { isSearching = true }
            }
        }
        .onDeleteCommand {
            guard let id = viewModel.sessionID,
                  let session = viewModel.sessions.first(where: { $0.id == id })
            else { return }
            Task { await viewModel.delete(session, settings: settings) }
        }
        .overlay {
            if !settings.isConfigured {
                ContentUnavailableView("Not connected", systemImage: "network.slash")
            } else if let error = viewModel.sessionsError, viewModel.sessions.isEmpty {
                ContentUnavailableView(
                    "Couldn't load history",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
            } else if viewModel.sessions.isEmpty {
                ContentUnavailableView("No conversations yet", systemImage: "clock.arrow.circlepath")
            } else if results.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionFooter(settings: settings)
        }
    }

    /// Picking a row opens that conversation; the selection itself is the
    /// view model's, so a new chat clears it and a sent one selects itself.
    private var selection: Binding<String?> {
        Binding(
            get: { viewModel.sessionID },
            set: { id in
                guard let id, let session = viewModel.sessions.first(where: { $0.id == id }) else { return }
                viewModel.open(session, settings: settings)
            }
        )
    }

    private func row(_ session: HermesSession) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(session.lastActivity, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// Filters on the title and on the opening of the first message.
    private var results: [HermesSession] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return viewModel.sessions }
        return viewModel.sessions.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(term)
                || (session.preview ?? "").localizedCaseInsensitiveContains(term)
        }
    }

    private var groups: [(title: String, sessions: [HermesSession])] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: today) ?? today
        let titles = [String(localized: "Today"), String(localized: "Yesterday"), String(localized: "Previous 7 Days"),
                      String(localized: "Previous 30 Days"), String(localized: "Older")]
        let buckets = Dictionary(grouping: results.sorted { $0.lastActivity > $1.lastActivity }) { session in
            let date = session.lastActivity
            if calendar.isDateInToday(date) { return 0 }
            if calendar.isDateInYesterday(date) { return 1 }
            if date >= weekAgo { return 2 }
            if date >= monthAgo { return 3 }
            return 4
        }
        return titles.indices.compactMap { index in
            buckets[index].map { (titles[index], $0) }
        }
    }
}

/// Which Hermes the window talks to, and whether it answers. A click opens
/// Settings, which is where either is changed.
private struct ConnectionFooter: View {
    let settings: SettingsStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                openSettings()
            } label: {
                HStack(spacing: 10) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Hermes · \(settings.normalizedProfile.isEmpty ? String(localized: "default", comment: "The default Hermes profile") : settings.normalizedProfile)")
                            .font(.system(size: 12, weight: .medium))
                        Text(settings.isConfigured ? (settings.baseURL.host() ?? "") : String(localized: "Not configured"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        // The list scrolls under the footer, so it needs a bar of its own
        // to stay legible over the rows.
        .background(.bar)
    }

    private var dotColor: Color {
        switch settings.connectionStatus {
        case .ok: .green
        case .failed: .red
        case .unknown, .checking: .secondary
        }
    }
}

private extension View {
    /// Binds the search field's focus where the system can (macOS 15 on).
    @ViewBuilder
    func searchFocus(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15, *) {
            searchFocused(focused)
        } else {
            self
        }
    }
}

// MARK: - Menus

/// The window's commands, in the menu bar where a Mac user looks for them.
struct ChatCommands: Commands {
    let viewModel: ChatViewModel
    let settings: SettingsStore

    /// The window's own New Chat, which can put the cursor in its composer.
    @FocusedValue(\.startNewChat) private var startNewChat
    @FocusedValue(\.searchConversations) private var searchConversations

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { startNewChat?() }
                .keyboardShortcut("n")
                .disabled(startNewChat == nil)
        }
        // The thread has no text of its own to find in, so ⌘F is the sidebar's.
        // Ahead of the Find submenu rather than replacing its group, which
        // would take Spelling and Substitutions out of the composer too.
        CommandGroup(before: .textEditing) {
            Button("Search Conversations") { searchConversations?() }
                .keyboardShortcut("f")
                .disabled(searchConversations == nil)
        }
        // Messages' wording, in the View menu. Bigger is ⌘1 rather than ⌘+,
        // which on a Swiss keyboard takes Shift as well. `.custom` keeps "−"
        // the character it is: the automatic localization would move it to
        // where "−" sits on a US keyboard.
        CommandGroup(before: .toolbar) {
            Button("Make Text Bigger") { stepTextSize(by: 1) }
                .keyboardShortcut("1")
                .disabled(textSizeStep == TextSize.steps.count - 1)
            Button("Make Text Normal Size") { settings.textSizeStep = nil }
                .keyboardShortcut("0")
                .disabled(settings.textSizeStep == nil)
            Button("Make Text Smaller") { stepTextSize(by: -1) }
                .keyboardShortcut("-", localization: .custom)
                .disabled(textSizeStep == 0)
            Divider()
        }
        CommandMenu("Chat") {
            Button("Stop") { viewModel.stop() }
                .keyboardShortcut(".")
                .disabled(!viewModel.isSending)
            Button("Verify") { viewModel.verify(settings: settings) }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!viewModel.canVerify)
            Divider()
            Button("Refresh History") {
                Task { await viewModel.refreshSessions(settings: settings) }
            }
            .keyboardShortcut("r")
        }
    }

    private var textSizeStep: Int {
        settings.textSizeStep ?? TextSize.systemStep
    }

    private func stepTextSize(by offset: Int) {
        let step = min(max(textSizeStep + offset, 0), TextSize.steps.count - 1)
        settings.textSizeStep = step == TextSize.systemStep ? nil : step
    }
}
extension FocusedValues {
    /// Starts a new chat in the main window and focuses its composer.
    var startNewChat: (() -> Void)? {
        get { self[StartNewChatKey.self] }
        set { self[StartNewChatKey.self] = newValue }
    }

    /// Focuses the main window's conversation search.
    var searchConversations: (() -> Void)? {
        get { self[SearchConversationsKey.self] }
        set { self[SearchConversationsKey.self] = newValue }
    }

    private struct StartNewChatKey: FocusedValueKey {
        typealias Value = () -> Void
    }

    private struct SearchConversationsKey: FocusedValueKey {
        typealias Value = () -> Void
    }
}
#endif
