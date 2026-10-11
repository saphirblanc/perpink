import Foundation

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isSending = false

    /// A passage copied out of the thread, waiting for a question to go with
    /// it: the next question is sent quoting it.
    var quote: String?

    /// Photos waiting to go out with the next question, ready-encoded.
    private(set) var attachments: [Data] = []
    private(set) var isPreparingPhotos = false

    /// What Hermes is busy with while it hasn't started answering — the tool
    /// it is running, say — shown under the spinner.
    var activity: String?

    /// A command Hermes wants permission to run, waiting on the user.
    var approval: ApprovalRequest?

    /// The last approval answered, so polling doesn't show it again while
    /// Hermes's status catches up.
    private var answeredApproval: ApprovalRequest?

    /// The Hermes session on screen; nil for a new chat that hasn't been sent yet.
    private(set) var sessionID: String?

    /// History, as Hermes has it.
    private(set) var sessions: [HermesSession] = []
    private(set) var sessionsError: String?
    private(set) var isLoadingThread = false

    private var runTask: Task<Void, Never>?

    /// The run being followed, mirrored on disk by `PendingRunStore`.
    private var pending: PendingRun?

    /// The client the current run was started with, so Stop and approvals go
    /// to the same profile even if Settings changed underneath.
    private var runClient: HermesClient?

    /// The answer being streamed into, if any.
    private var activeAssistantID: UUID?

    /// True between a connection that dropped and the attempt that picks the run
    /// back up. The answer keeps its spinner: from the user's side Hermes never
    /// stopped — and on the server it didn't.
    private var isAwaitingResume = false

    /// Consecutive failed attempts to reach a run while the app is on screen.
    private var foregroundRetries = 0
    private static let maxForegroundRetries = 3

    /// Keeps the stream open for a while after the app leaves the screen.
    private let backgroundActivity = BackgroundActivity()

    private var isForeground = true

    /// When the app last left the screen, to tell a glance away from a real absence.
    private var backgroundedAt: Date?

    /// Streamed text not yet on screen, and the timer that will apply it.
    private var bufferedDelta = ""
    private var flushTask: Task<Void, Never>?

    // MARK: - Sending

    var canSend: Bool {
        !isSending && !isPreparingPhotos
            && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func send(settings: SettingsStore) {
        guard canSend else { return }
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let question = Self.compose(typed, quoting: quote)
        let images = attachments
        attachments = []
        quote = nil
        // The keyboard can commit pending autocorrect text back into the
        // field after a synchronous clear, so sweep it again shortly after.
        input = ""
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if !typed.isEmpty, input.trimmingCharacters(in: .whitespacesAndNewlines) == typed {
                input = ""
            }
        }
        submit(question, images: images, settings: settings)
    }

    /// A follow-up goes out with the passage it is about quoted above it,
    /// which is how a model is told "this bit, specifically" — and how the
    /// thread still shows what was asked when it is read back from Hermes.
    private static func compose(_ question: String, quoting quote: String?) -> String {
        guard let quote, !quote.isEmpty else { return question }
        let passage = quote
            .components(separatedBy: .newlines)
            .map { $0.isEmpty ? ">" : "> " + $0 }
            .joined(separator: "\n")
        return question.isEmpty ? passage : passage + "\n\n" + question
    }

    // MARK: - Verifying

    /// Only the newest answer offers it: the prompt talks about the answer
    /// Hermes just gave, and nothing else may be in flight.
    var canVerify: Bool {
        guard !isSending, !isPreparingPhotos, sessionID != nil, let last = messages.last else { return false }
        return last.role == .assistant && !last.isError && !last.text.isEmpty
    }

    /// Sends the last answer back for a second pass, against the web this time.
    /// Being this explicit pays off: asked only to double-check, a model restates
    /// what it already said from memory instead of going to look.
    func verify(settings: SettingsStore) {
        guard canVerify else { return }
        submit(Self.verifyPrompt, images: [], settings: settings)
    }

    /// Not localized: Hermes answers in the language of the conversation, and
    /// a request in the interface's language would pull it towards that one.
    private static let verifyPrompt = """
        Check the answer you just gave me against the web. Search for independent, \
        current sources instead of trusting what you already said, then tell me \
        which of your claims they confirm, which need correcting, and which you \
        couldn't settle — with the links you relied on. Answer in the language \
        of our conversation.
        """

    /// Puts a question in the thread and starts the run that answers it.
    private func submit(_ question: String, images: [Data], settings: SettingsStore) {
        messages.append(ChatMessage(role: .user, text: question, images: images))
        guard settings.isConfigured else {
            messages.append(.error(String(localized: "Set the server and API key in Settings first.")))
            return
        }

        let isNewSession = sessionID == nil
        let id = sessionID ?? Self.newSessionID()
        sessionID = id
        let run = PendingRun(
            sessionID: id,
            needsSession: isNewSession,
            question: question,
            images: images,
            idempotencyKey: UUID().uuidString,
            runID: nil,
            startedAt: Date()
        )
        follow(run, client: settings.client)
    }

    // MARK: - Photos

    var remainingPhotoSlots: Int {
        PhotoAttachment.maxCount - attachments.count
    }

    /// Adds photos picked from the library or taken with the camera. Encoding
    /// happens off the main thread: a full-size photo takes a moment to scale.
    func attach(_ loaders: [@Sendable () async -> Data?]) {
        guard !loaders.isEmpty else { return }
        isPreparingPhotos = true
        Task {
            defer { isPreparingPhotos = false }
            for load in loaders.prefix(remainingPhotoSlots) {
                guard let jpeg = await load() else { continue }
                guard remainingPhotoSlots > 0 else { break }
                attachments.append(jpeg)
            }
        }
    }

    func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
    }

    func stop() {
        guard isSending else { return }
        if let runID = pending?.runID, let client = runClient {
            Task { try? await client.stopRun(runID: runID) }
        }
        runTask?.cancel()
        runTask = nil
        if let id = activeAssistantID {
            flushStream()
            settle(id, text: nil, fallback: String(localized: "Stopped."))
        }
    }

    func answer(_ choice: String) {
        guard let request = approval, let runID = pending?.runID, let client = runClient else { return }
        approval = nil
        answeredApproval = request
        activity = nil
        Task {
            do {
                try await client.answerApproval(runID: runID, requestID: request.requestId, choice: choice)
            } catch {
                // Put the question back so it can be answered again.
                if pending?.runID == runID {
                    answeredApproval = nil
                    approval = request
                }
            }
        }
    }

    // MARK: - Threads

    func newChat() {
        abandonRun()
        attachments = []
        quote = nil
        messages = []
        sessionID = nil
    }

    func refreshSessions(settings: SettingsStore) async {
        guard settings.isConfigured else {
            sessions = []
            return
        }
        do {
            sessions = try await settings.client.listSessions()
            sessionsError = nil
        } catch {
            sessionsError = error.localizedDescription
        }
    }

    func open(_ session: HermesSession, settings: SettingsStore) {
        guard session.id != sessionID || isSending else { return }
        abandonRun()
        quote = nil
        sessionID = session.id
        messages = []
        isLoadingThread = true
        Task {
            defer { if sessionID == session.id { isLoadingThread = false } }
            do {
                let transcript = try await settings.client.messages(sessionID: session.id)
                guard sessionID == session.id else { return }
                messages = ChatMessage.thread(from: transcript)
            } catch {
                guard sessionID == session.id else { return }
                messages = [.error(String(localized: "Couldn't load this conversation: \(error.localizedDescription)"))]
            }
        }
    }

    func delete(_ session: HermesSession, settings: SettingsStore) async {
        do {
            try await settings.client.deleteSession(id: session.id)
            sessions.removeAll { $0.id == session.id }
            if session.id == sessionID { newChat() }
        } catch {
            sessionsError = error.localizedDescription
        }
    }

    // MARK: - Scene phase

    func enteredBackground() {
        isForeground = false
        backgroundedAt = Date()
    }

    /// Called on every activation and once at launch, which is where a run that
    /// outlived its connection — or the whole process — is picked up again.
    func enteredForeground(settings: SettingsStore) {
        isForeground = true
        foregroundRetries = 0
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundedAt = nil
        // A stream held across a longer absence may be a dead socket that
        // won't say so until it times out; go and ask the run directly.
        if isSending, !isAwaitingResume, away > 5 {
            isAwaitingResume = true
        }
        resumeIfNeeded(settings: settings)
    }

    // MARK: - Following a run

    /// Puts a placeholder answer on screen and follows `run` to its end.
    private func follow(_ run: PendingRun, client: HermesClient, live: Bool = true) {
        if activeAssistantID == nil {
            let assistant = ChatMessage(role: .assistant, text: "", isStreaming: true)
            messages.append(assistant)
            activeAssistantID = assistant.id
        }
        guard let assistantID = activeAssistantID else { return }
        pending = run
        runClient = client
        isSending = true
        isAwaitingResume = false
        // On disk before the first request: from here the run can be found
        // again whatever happens to this process.
        PendingRunStore.save(run)
        backgroundActivity.begin(name: "Hermes run")

        runTask = Task { await drive(client: client, assistantID: assistantID, live: live) }
    }

    /// `live` joins the run's event stream. Only the first attempt does: Hermes
    /// has one event queue per run, and a second listener next to a connection
    /// that died without saying so would split the events between them.
    private func drive(client: HermesClient, assistantID: UUID, live: Bool) async {
        do {
            guard var run = pending else { return }
            // After each request: if the user moved on meanwhile, this run is no
            // longer the one on disk, and must not be written back over it.
            if run.needsSession {
                let title = run.question.isEmpty ? String(localized: "Photo") : String(run.question.prefix(80))
                try await client.createSession(id: run.sessionID, title: title)
                guard activeAssistantID == assistantID else { return }
                run.needsSession = false
                record(run)
            }
            if run.runID == nil {
                run.runID = try await client.startRun(
                    input: run.question, images: run.images,
                    sessionID: run.sessionID, idempotencyKey: run.idempotencyKey)
                guard activeAssistantID == assistantID else { return }
                record(run)
            }
            guard let runID = run.runID else { return }
            try await track(runID: runID, client: client, assistantID: assistantID, live: live)
        } catch {
            guard !Task.isCancelled, activeAssistantID == assistantID else { return }
            flushStream()
            handle(error, client: client, assistantID: assistantID)
        }
    }

    /// Follows a started run: live events while they can be had, then the
    /// run's status. Hermes keeps one event stream per run, and once its
    /// listener has gone — this app suspended, say — rejoining it answers 404.
    /// The run itself carries on regardless, so polling picks up the ending.
    private func track(runID: String, client: HermesClient, assistantID: UUID, live: Bool) async throws {
        if live {
            do {
                for try await event in client.events(runID: runID) {
                    try Task.checkCancellation()
                    foregroundRetries = 0
                    if apply(event, to: assistantID) { return }
                }
            } catch HermesError.httpError(404, _) {
                // No live stream to join; fall through to polling.
            }
        }

        activity = activity ?? String(localized: "Working…")
        while true {
            try Task.checkCancellation()
            guard let status = try await client.runStatus(runID: runID) else {
                // Hermes no longer remembers the run; the transcript does.
                try await recoverFromTranscript(client: client, assistantID: assistantID)
                return
            }
            foregroundRetries = 0
            if status.isFinished {
                finish(status, assistantID: assistantID)
                return
            }
            if status.status == "waiting_for_approval", let request = status.approval,
               request != answeredApproval {
                approval = request
                activity = String(localized: "Waiting for your approval")
            }
            try await Task.sleep(for: .seconds(2))
        }
    }

    /// Applies one event. Returns true once the run is over.
    private func apply(_ event: RunEvent, to id: UUID) -> Bool {
        switch event {
        case .delta(let delta):
            activity = nil
            stream(delta, to: id)
        case .interim(let text, let alreadyStreamed):
            if !alreadyStreamed, !text.isEmpty { stream(text + "\n\n", to: id) }
        case .toolStarted(let name, let preview):
            activity = Self.describe(tool: name, preview: preview)
        case .toolCompleted:
            break
        case .approval(let request):
            approval = request
            activity = String(localized: "Waiting for your approval")
        case .completed(let output):
            flushStream()
            settle(id, text: output, fallback: nil)
            return true
        case .failed(let message):
            flushStream()
            fail(id, message: message)
            return true
        case .cancelled:
            flushStream()
            settle(id, text: nil, fallback: String(localized: "Stopped."))
            return true
        case .ignored:
            break
        }
        return false
    }

    private func finish(_ status: RunStatus, assistantID: UUID) {
        flushStream()
        switch status.status {
        case "completed":
            settle(assistantID, text: status.output, fallback: nil)
        case "failed":
            fail(assistantID, message: status.error ?? String(localized: "The run failed."))
        default:
            settle(assistantID, text: status.output, fallback: String(localized: "Stopped."))
        }
    }

    /// The run's status has expired, so read the answer out of the session.
    private func recoverFromTranscript(client: HermesClient, assistantID: UUID) async throws {
        guard let run = pending else { return }
        let thread = ChatMessage.thread(from: try await client.messages(sessionID: run.sessionID))
        guard sessionID == run.sessionID, activeAssistantID == assistantID else { return }
        if let questionIndex = thread.lastIndex(where: { $0.role == .user && $0.text == run.question }),
           thread.indices.contains(questionIndex + 1) {
            settle(assistantID, text: thread[questionIndex + 1].text, fallback: nil)
        } else {
            fail(assistantID, message: String(localized: "Hermes lost track of this answer. Ask again?"))
        }
    }

    /// Decides what a failure meant. A dropped connection is not the run
    /// failing — Hermes carries on without us — so the run is picked up again:
    /// straight away if the app is on screen, otherwise on the way back in.
    private func handle(_ error: Error, client: HermesClient, assistantID: UUID) {
        guard isRecoverable(error), let run = pending, run.isResumable else {
            fail(assistantID, message: error.localizedDescription)
            return
        }
        isAwaitingResume = true
        if isForeground {
            foregroundRetries += 1
            guard foregroundRetries <= Self.maxForegroundRetries else {
                fail(assistantID, message: error.localizedDescription)
                return
            }
            activity = String(localized: "Reconnecting…")
            runTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, isAwaitingResume, activeAssistantID == assistantID else { return }
                isAwaitingResume = false
                await drive(client: client, assistantID: assistantID, live: false)
            }
        } else {
            // Nothing to protect until the app is opened again.
            backgroundActivity.end()
        }
    }

    /// Errors that mean the connection went away, rather than Hermes refusing.
    private func isRecoverable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost, .notConnectedToInternet, .timedOut,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff, .cancelled,
                 .backgroundSessionWasDisconnected:
                return true
            default:
                return false
            }
        }
        if case HermesError.streamInterrupted = error { return true }
        if case HermesError.tooManyRuns = error { return true }
        return false
    }

    // MARK: - Resuming

    /// Picks up a run whose answer hasn't been seen. Does nothing while one is
    /// still being followed, so a connection that survived the trip is left alone.
    func resumeIfNeeded(settings: SettingsStore) {
        guard !isSending || isAwaitingResume else { return }
        guard let run = PendingRunStore.load() ?? pending, run.isResumable else {
            PendingRunStore.clear()
            if isAwaitingResume, let id = activeAssistantID {
                fail(id, message: HermesError.streamInterrupted.localizedDescription)
            }
            return
        }
        let client = runClient ?? settings.client

        if sessionID == run.sessionID, isAwaitingResume {
            // Same thread, still on screen: carry on where it stopped.
            runTask?.cancel()
            flushStream()
            follow(run, client: client, live: false)
            return
        }

        // After a relaunch: restore the thread, then follow the run.
        abandonRun()
        sessionID = run.sessionID
        messages = [ChatMessage(role: .user, text: run.question, images: run.images)]
        follow(run, client: client)
        Task {
            guard !run.needsSession,
                  let transcript = try? await client.messages(sessionID: run.sessionID),
                  sessionID == run.sessionID
            else { return }
            // Everything before the question; the question and its answer are
            // this run's to show.
            var thread = ChatMessage.thread(from: transcript)
            if let index = thread.lastIndex(where: { $0.role == .user && $0.text == run.question }) {
                thread.removeSubrange(index...)
            }
            messages.insert(contentsOf: thread, at: 0)
        }
    }

    /// Stops following the current run without recording anything. The run
    /// itself carries on at Hermes, and its answer lands in the session.
    private func abandonRun() {
        runTask?.cancel()
        runTask = nil
        cancelStreamBuffer()
        if let id = activeAssistantID, let index = index(of: id) {
            messages[index].isStreaming = false
        }
        clearRunState()
    }

    private func clearRunState() {
        PendingRunStore.clear()
        backgroundActivity.end()
        pending = nil
        runClient = nil
        activeAssistantID = nil
        isSending = false
        isAwaitingResume = false
        foregroundRetries = 0
        activity = nil
        approval = nil
        answeredApproval = nil
    }

    private func record(_ run: PendingRun) {
        pending = run
        PendingRunStore.save(run)
    }

    // MARK: - Streamed text

    /// How often streamed text reaches the view.
    private static let refreshInterval = Duration.milliseconds(80)

    /// Applies streamed text on a timer instead of per chunk: `MarkdownView`
    /// re-parses whatever it is handed, and deltas arrive a few words at a time.
    private func stream(_ delta: String, to id: UUID) {
        bufferedDelta += delta
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            do { try await Task.sleep(for: Self.refreshInterval) } catch { return }
            flushTask = nil
            flushStream()
        }
    }

    /// Puts the buffered text on screen now, before anything reads the answer.
    private func flushStream() {
        guard !bufferedDelta.isEmpty, let id = activeAssistantID, let index = index(of: id) else { return }
        messages[index].text += bufferedDelta
        bufferedDelta = ""
    }

    private func cancelStreamBuffer() {
        flushTask?.cancel()
        flushTask = nil
        bufferedDelta = ""
    }

    // MARK: - Settling

    /// Ends the run on screen. A complete stream is kept as it is — it includes
    /// commentary the final output leaves out — but one that doesn't hold the
    /// whole output (it was cut off, or nothing streamed) gives way to it.
    private func settle(_ id: UUID, text: String?, fallback: String?) {
        guard activeAssistantID == id else { return }
        cancelStreamBuffer()
        if let index = index(of: id) {
            let output = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty, !messages[index].text.contains(output) {
                messages[index].text = output
            } else if messages[index].text.isEmpty {
                messages[index].text = fallback ?? ""
            }
            messages[index].isStreaming = false
            if messages[index].text.isEmpty { messages.remove(at: index) }
        }
        clearRunState()
    }

    private func fail(_ id: UUID, message: String) {
        guard activeAssistantID == id else { return }
        cancelStreamBuffer()
        if let index = index(of: id) {
            messages[index].isStreaming = false
            if messages[index].text.isEmpty {
                messages[index].isError = true
                messages[index].text = String(localized: "Something went wrong: \(message)")
            } else {
                messages.insert(.error(message), at: index + 1)
            }
        }
        clearRunState()
    }

    // MARK: - Private

    private func index(of id: UUID) -> Int? {
        messages.firstIndex(where: { $0.id == id })
    }

    private static func newSessionID() -> String {
        "perpink_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func describe(tool: String, preview: String?) -> String {
        let name = tool.replacingOccurrences(of: "_", with: " ").capitalized
        guard let preview, !preview.isEmpty else { return name + "…" }
        return "\(name) · \(preview)"
    }
}
