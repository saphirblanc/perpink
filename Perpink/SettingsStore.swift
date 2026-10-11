import Foundation

@MainActor
@Observable
final class SettingsStore {
    private enum Key {
        static let server = "hermesServerURL"
        static let profile = "hermesProfile"
        static let seeded = "hermesSeeded"
        static let textSize = "textSizeStep"
    }

    /// The API server's address, e.g. `http://<host>:8642`. Plain HTTP is
    /// allowed to any host, since every user brings their own server.
    var serverURLString: String {
        didSet { UserDefaults.standard.set(serverURLString, forKey: Key.server) }
    }

    /// The Hermes profile to talk to. Empty (or "default") is the default
    /// profile; anything else is reached under `/p/<profile>/`, which only
    /// accepts that profile's own `API_SERVER_KEY`.
    var profile: String {
        didSet { UserDefaults.standard.set(profile, forKey: Key.profile) }
    }

    /// The profile's `API_SERVER_KEY`. Stored in the Keychain, never in UserDefaults.
    var apiKey: String {
        didSet { KeychainHelper.saveAPIKey(apiKey) }
    }

    /// The conversation's text size, as a step along `TextSize.steps`; nil
    /// leaves it to the system.
    var textSizeStep: Int? {
        didSet { UserDefaults.standard.set(textSizeStep, forKey: Key.textSize) }
    }

    private(set) var connectionStatus: ConnectionStatus = .unknown

    enum ConnectionStatus: Equatable {
        case unknown
        case checking
        case ok
        case failed(String)
    }

    init() {
        let defaults = UserDefaults.standard
        // Seed from Secrets.plist, once, on first launch. Without the file the
        // fields start empty and are typed into Settings instead.
        if !defaults.bool(forKey: Key.seeded) {
            if let server = Secrets.defaultServerURL { defaults.set(server, forKey: Key.server) }
            if let key = Secrets.seedAPIKey { KeychainHelper.saveAPIKey(key) }
            if let profile = Secrets.defaultProfile { defaults.set(profile, forKey: Key.profile) }
            defaults.set(true, forKey: Key.seeded)
        }
        serverURLString = defaults.string(forKey: Key.server) ?? ""
        profile = defaults.string(forKey: Key.profile) ?? ""
        apiKey = KeychainHelper.readAPIKey() ?? ""
        textSizeStep = defaults.object(forKey: Key.textSize) as? Int
    }

    var isConfigured: Bool {
        !serverURLString.trimmingCharacters(in: .whitespaces).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var normalizedProfile: String {
        let name = profile.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "default" ? "" : name
    }

    /// The server URL, with the profile prefix when a named profile is selected.
    var baseURL: URL {
        var string = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        // A tailnet API server speaks plain HTTP (WireGuard already encrypts it).
        if !string.contains("://") { string = "http://" + string }
        while string.hasSuffix("/") { string.removeLast() }
        if !normalizedProfile.isEmpty {
            string += "/p/" + (normalizedProfile.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? normalizedProfile)
        }
        // A server field that doesn't parse resolves to a host that cannot
        // exist, so the request fails with a plain DNS error rather than being
        // sent somewhere the user didn't ask for.
        return URL(string: string) ?? URL(string: "http://unconfigured.invalid")!
    }

    var client: HermesClient {
        HermesClient(baseURL: baseURL, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Checks the server, profile and key together, by listing one session.
    func checkConnection() async {
        connectionStatus = .checking
        do {
            _ = try await client.listSessions(limit: 1)
            connectionStatus = .ok
        } catch HermesError.httpError(404, _) {
            connectionStatus = .failed(String(localized: "This server doesn't serve a profile named “\(normalizedProfile)”."))
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }

    func resetConnectionStatus() {
        connectionStatus = .unknown
    }
}
