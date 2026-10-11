import Foundation

// MARK: - /api/sessions

struct HermesSession: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String?
    /// The opening of the first message, for sessions that were never titled.
    let preview: String?
    let startedAt: Double
    let lastActive: Double?

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let preview, !preview.isEmpty { return preview }
        return "Conversation"
    }

    var lastActivity: Date {
        Date(timeIntervalSince1970: lastActive ?? startedAt)
    }
}

/// One row of a session transcript. Tool calls and tool results are rows too;
/// the app only shows what was said.
struct HermesMessage: Decodable, Sendable {
    let role: String
    let content: String?

    private enum CodingKeys: String, CodingKey { case role, content }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        // Multimodal turns carry an array of parts rather than a string.
        content = try? container.decode(String.self, forKey: .content)
    }
}

// MARK: - /v1/runs

struct RunStatus: Decodable, Sendable {
    let status: String
    let output: String?
    let error: String?
    /// Present while the run is parked on `waiting_for_approval`.
    let approval: ApprovalRequest?

    var isFinished: Bool {
        ["completed", "failed", "cancelled", "interrupted"].contains(status)
    }
}

/// Hermes stopped to ask before running something — usually a terminal command.
struct ApprovalRequest: Decodable, Hashable, Sendable {
    let requestId: String?
    let command: String?
    let description: String?
    let choices: [String]?

    var offeredChoices: [String] { choices ?? ["once", "deny"] }

    static func title(for choice: String) -> String {
        switch choice {
        case "once": String(localized: "Allow once")
        case "session": String(localized: "Allow for this chat")
        case "always": String(localized: "Always allow")
        case "deny": String(localized: "Deny")
        default: choice.capitalized
        }
    }
}

/// One event from `GET /v1/runs/{id}/events`, keyed on its `event` field.
enum RunEvent: Decodable, Sendable {
    case delta(String)
    case toolStarted(name: String, preview: String?)
    case toolCompleted(name: String)
    /// Mid-turn commentary: text the agent says while it keeps working.
    case interim(String, alreadyStreamed: Bool)
    case approval(ApprovalRequest)
    case completed(output: String)
    case failed(String)
    case cancelled
    case ignored

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case event, delta, tool, preview, text, alreadyStreamed, output, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let string = { (key: CodingKeys) in try? c.decode(String.self, forKey: key) }
        switch string(.event) ?? "" {
        case "message.delta":
            self = .delta(string(.delta) ?? "")
        case "tool.started":
            self = .toolStarted(name: string(.tool) ?? "tool", preview: string(.preview))
        case "tool.completed":
            self = .toolCompleted(name: string(.tool) ?? "tool")
        case "message.interim":
            self = .interim(string(.text) ?? "", alreadyStreamed: (try? c.decode(Bool.self, forKey: .alreadyStreamed)) ?? false)
        case "approval.request":
            self = .approval(try ApprovalRequest(from: decoder))
        case "run.completed":
            self = .completed(output: string(.output) ?? "")
        case "run.failed":
            self = .failed(string(.error) ?? String(localized: "The run failed."))
        case "run.cancelled", "run.interrupted":
            self = .cancelled
        default:
            self = .ignored
        }
    }
}

// MARK: - Chat

struct ChatMessage: Identifiable {
    enum Role {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    /// Photos sent with a question, as the JPEGs that went to Hermes.
    var images: [Data]
    /// Photos known only by their trace in a transcript: Hermes keeps text,
    /// not images, so a reloaded conversation can say a photo was there but
    /// can't show it.
    var missingPhotos: Int
    var isStreaming: Bool
    var isError: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        images: [Data] = [],
        missingPhotos: Int = 0,
        isStreaming: Bool = false,
        isError: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.images = images
        self.missingPhotos = missingPhotos
        self.isStreaming = isStreaming
        self.isError = isError
    }

    static func error(_ text: String) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, isError: true)
    }

    /// A question split into the passage it is about and what was asked about
    /// it. Leading `>` lines are how a follow-up carries its passage — in the
    /// thread as it is sent, and again in a conversation read back from Hermes.
    var quoted: (passage: String?, question: String) {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.hasPrefix(">") == true else { return (nil, text) }
        var passage: [String] = []
        var index = 0
        while index < lines.count, lines[index].hasPrefix(">") {
            var content = Substring(lines[index]).dropFirst()
            if content.hasPrefix(" ") { content = content.dropFirst() }
            passage.append(String(content))
            index += 1
        }
        let question = lines[index...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (passage.joined(separator: "\n"), question)
    }

    /// A session transcript as the thread shows it: what the user said, and what
    /// Hermes said back. Tool traffic is dropped, and consecutive assistant rows
    /// — commentary between tool calls, then the answer — read as one reply.
    static func thread(from transcript: [HermesMessage]) -> [ChatMessage] {
        var thread: [ChatMessage] = []
        for row in transcript {
            let text = (row.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch row.role {
            case "user":
                thread.append(userMessage(fromStored: text))
            case "assistant":
                if let last = thread.indices.last, thread[last].role == .assistant {
                    thread[last].text += "\n\n" + text
                } else {
                    thread.append(ChatMessage(role: .assistant, text: text))
                }
            default:
                continue
            }
        }
        return thread
    }

    /// How Hermes stores a question that carried photos: its text parts, with
    /// each image flattened to `[screenshot]`. A plugin may also have appended
    /// its own prompt to that first message (superpowers does), which is not
    /// something the user said — so for a question with photos, what follows
    /// the last one is dropped. Perpink always sends the text before the photos.
    private static func userMessage(fromStored text: String) -> ChatMessage {
        let token = "[screenshot]"
        guard let last = text.range(of: token, options: .backwards) else {
            return ChatMessage(role: .user, text: text)
        }
        let kept = text[..<last.upperBound]
        let photos = kept.components(separatedBy: token).count - 1
        let words = kept.replacingOccurrences(of: token, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ChatMessage(role: .user, text: words, missingPhotos: photos)
    }
}
