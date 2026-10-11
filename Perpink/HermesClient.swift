import Foundation

enum HermesError: LocalizedError {
    case httpError(Int, String?)
    case unauthorized
    case tooManyRuns
    case unexpectedResponse
    case streamInterrupted
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let message):
            return message.map { String(localized: "Hermes returned HTTP \(code): \($0)") } ?? String(localized: "Hermes returned HTTP \(code).")
        case .unauthorized:
            return String(localized: "Hermes refused the API key. Check the profile and key in Settings.")
        case .tooManyRuns:
            return String(localized: "Hermes is busy with too many runs. Try again in a moment.")
        case .unexpectedResponse:
            return String(localized: "Hermes returned an unexpected response.")
        case .streamInterrupted:
            return String(localized: "The connection to Hermes was interrupted.")
        case .runFailed(let message):
            return message
        }
    }
}

/// Talks to the Hermes Agent API server — the gateway's `api_server` platform.
///
/// Every route is the documented one (hermes-agent.nousresearch.com/docs/user-guide/features/api-server):
/// conversations are Hermes *sessions* (`/api/sessions`), and a question is a *run*
/// (`POST /v1/runs`) whose progress streams from `/v1/runs/{id}/events`. Runs
/// execute server-side and keep going if this app is suspended mid-answer, which
/// is why the app uses them rather than `/api/sessions/{id}/chat/stream` — that
/// one interrupts the agent the moment its client disconnects.
///
/// With multiplexed profiles, a named profile lives under `/p/<profile>/` and only
/// answers to its own `API_SERVER_KEY`; `baseURL` already carries that prefix.
final class HermesClient: Sendable {
    let baseURL: URL
    let apiKey: String

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }

    // MARK: - Sessions

    /// Sessions this app (or any other API client) started, newest activity first.
    func listSessions(limit: Int = 100) async throws -> [HermesSession] {
        let data = try await get("api/sessions", query: [
            URLQueryItem(name: "source", value: "api_server"),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
        return try Self.decoder.decode(ListResponse<HermesSession>.self, from: data).data
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Creates a session under an id chosen here, so a create that is retried
    /// after a dropped connection lands on the same session instead of a twin.
    func createSession(id: String, title: String) async throws {
        var request = makeRequest("api/sessions", method: "POST")
        request.httpBody = try JSONEncoder().encode(["id": id, "title": title])
        let (data, response) = try await URLSession.shared.data(for: request)
        // 409: it already exists — the earlier attempt got through.
        if (response as? HTTPURLResponse)?.statusCode == 409 { return }
        try validate(response, data: data)
    }

    func deleteSession(id: String) async throws {
        let request = makeRequest("api/sessions/\(id)", method: "DELETE")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    func messages(sessionID: String) async throws -> [HermesMessage] {
        let data = try await get("api/sessions/\(sessionID)/messages", query: [
            URLQueryItem(name: "inline_images", value: "false"),
        ])
        return try Self.decoder.decode(ListResponse<HermesMessage>.self, from: data).data
    }

    // MARK: - Runs

    /// Starts a turn in `sessionID`. The idempotency key makes this safe to repeat:
    /// Hermes answers a retry of the same key with the run it already started —
    /// provided the body is the same, which is why photos are sent as the exact
    /// JPEG bytes the caller keeps.
    func startRun(input: String, images: [Data] = [], sessionID: String, idempotencyKey: String) async throws -> String {
        var request = makeRequest("v1/runs", method: "POST")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        // Photos may take a while to upload on a mobile link.
        request.timeoutInterval = images.isEmpty ? 30 : 120
        request.httpBody = try JSONEncoder().encode(RunRequest(input: input, images: images, sessionID: sessionID))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try Self.decoder.decode(RunStarted.self, from: data).runId
    }

    /// The run's current state, or nil once Hermes no longer remembers it —
    /// statuses are only kept briefly after a run ends.
    func runStatus(runID: String) async throws -> RunStatus? {
        let request = makeRequest("v1/runs/\(runID)", method: "GET")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try validate(response, data: data)
        return try Self.decoder.decode(RunStatus.self, from: data)
    }

    func stopRun(runID: String) async throws {
        let request = makeRequest("v1/runs/\(runID)/stop", method: "POST")
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    func answerApproval(runID: String, requestID: String?, choice: String) async throws {
        var request = makeRequest("v1/runs/\(runID)/approval", method: "POST")
        var body = ["choice": choice]
        if let requestID { body["request_id"] = requestID }
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
    }

    /// The run's live events. Hermes keeps one event queue per run, so this can
    /// only be joined while the run is going; a 404 here means "follow it by
    /// polling `runStatus` instead".
    func events(runID: String) -> AsyncThrowingStream<RunEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = makeRequest("v1/runs/\(runID)/events", method: "GET")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    // Hermes sends a keepalive comment every 10 seconds, so a
                    // long silence really is a dead connection.
                    request.timeoutInterval = 60
                    let config = URLSessionConfiguration.default
                    config.timeoutIntervalForRequest = 60
                    config.timeoutIntervalForResource = 60 * 60
                    let session = URLSession(configuration: config)
                    defer { session.finishTasksAndInvalidate() }

                    let (bytes, response) = try await session.bytes(for: request)
                    try validate(response, data: nil)

                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        // Lines starting with ":" are keepalive comments.
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let event = try? Self.decoder.decode(RunEvent.self, from: data)
                        else { continue }
                        continuation.yield(event)
                        if event.isTerminal {
                            continuation.finish()
                            return
                        }
                    }
                    // The stream closed without a terminal event.
                    continuation.finish(throwing: HermesError.streamInterrupted)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Files

    /// A file the agent pointed to with `MEDIA:<path>` — a path on its own
    /// host. Hermes serves none of those; a proxy in front of it can, at
    /// `files<path>` under the profile's prefix and behind the same key. A
    /// server without that route answers 404, and the file stays out of reach.
    func file(at path: String) async throws -> Data {
        var request = makeRequest("files" + path, method: "GET")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: nil)
        return data
    }

    // MARK: - Plumbing

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = baseURL.appendingPathComponent(path)
        guard !query.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.queryItems = query
        return components.url ?? url
    }

    private func makeRequest(_ path: String, method: String, query: [URLQueryItem] = []) -> URLRequest {
        var request = URLRequest(url: url(path, query: query))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func get(_ path: String, query: [URLQueryItem]) async throws -> Data {
        let request = makeRequest(path, method: "GET", query: query)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return data
    }

    private func validate(_ response: URLResponse, data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { throw HermesError.unexpectedResponse }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw HermesError.unauthorized
        case 429:
            throw HermesError.tooManyRuns
        default:
            throw HermesError.httpError(http.statusCode, data.flatMap(Self.errorMessage))
        }
    }

    /// The `error.message` (or bare `error`) out of a Hermes error body.
    private static func errorMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error"] as? String
    }
}

private struct ListResponse<Item: Decodable>: Decodable {
    let data: [Item]
}

private struct RunStarted: Decodable {
    let runId: String
}

/// `POST /v1/runs`. Text alone goes as a plain string. With photos, the input is
/// one user message whose content is a list of parts in the Chat Completions
/// shape (`text`, `image_url`): `/v1/runs` hands that content to the agent
/// as it is, and the agent reads that shape — the Responses one
/// (`input_text`, `input_image`) reaches the model as neither text nor image.
private struct RunRequest: Encodable {
    let input: String
    let images: [Data]
    let sessionID: String

    private enum CodingKeys: String, CodingKey { case input, instructions, sessionID = "session_id" }

    /// Sent with photos, as the run's ephemeral system layer. An attached photo
    /// exists only inside the message — Hermes saves it nowhere — but models
    /// reach for `vision_analyze` to "look closer", invent a file path, and then
    /// search the disk for it. This says there is nothing to find.
    static let photoInstructions = """
        The user attached photos to this message. You see them directly in the \
        message. They are not saved anywhere: they have no file path or URL, so \
        vision_analyze, the terminal and file tools cannot open them. Do not look \
        for them; answer from what you see, and ask the user for another photo \
        if you need a closer or different view.
        """

    private struct Message: Encodable {
        let role = "user"
        let content: [Part]
    }

    private struct Part: Encodable {
        let type: String
        var text: String?
        var imageURL: ImageURL?

        struct ImageURL: Encodable { let url: String }

        private enum CodingKeys: String, CodingKey { case type, text, imageURL = "image_url" }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionID, forKey: .sessionID)
        guard !images.isEmpty else {
            try container.encode(input, forKey: .input)
            return
        }
        var parts: [Part] = []
        if !input.isEmpty { parts.append(Part(type: "text", text: input)) }
        for image in images {
            let url = "data:image/jpeg;base64," + image.base64EncodedString()
            parts.append(Part(type: "image_url", imageURL: .init(url: url)))
        }
        try container.encode([Message(content: parts)], forKey: .input)
        try container.encode(Self.photoInstructions, forKey: .instructions)
    }
}
