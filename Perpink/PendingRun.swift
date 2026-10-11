import Foundation

/// A question sent to Hermes whose answer hasn't been seen yet.
///
/// Written to disk before the first request and cleared once the answer is on
/// screen, so it outlives whatever interrupts it — the app suspended in the
/// background, or killed outright. Hermes keeps working on a run after its
/// client goes away, so picking this up never means asking again: it means
/// finding the run and reading what it produced.
///
/// Every step is safe to repeat. The session id is chosen here, and the run is
/// started under `idempotencyKey`, which Hermes answers with the same run for
/// 24 hours — so a record that died before learning its `runID` can simply
/// redo the start and be handed the run that already exists.
struct PendingRun: Codable, Sendable {
    let sessionID: String
    /// Whether the session still has to be created (the question opened a new chat).
    var needsSession: Bool
    let question: String
    /// The photos sent with the question, byte for byte: a repeated start must
    /// send the very same body, or Hermes refuses the reused idempotency key.
    let images: [Data]
    let idempotencyKey: String
    var runID: String?
    let startedAt: Date

    /// Past this the answer is left to the history list: coming back to a
    /// spinner for something asked yesterday would be a surprise.
    static let resumeWindow: TimeInterval = 6 * 60 * 60

    var isResumable: Bool {
        Date().timeIntervalSince(startedAt) < Self.resumeWindow
    }
}

/// The single in-flight run, as a file in Application Support.
@MainActor
enum PendingRunStore {
    private static var fileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return directory.appendingPathComponent("pending-run.json")
    }

    static func load() -> PendingRun? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(PendingRun.self, from: data)
    }

    static func save(_ pending: PendingRun) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
