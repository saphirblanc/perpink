import Foundation

/// Build-time configuration that shouldn't live in source control.
///
/// Values come from `Perpink/Secrets.plist`, which is gitignored;
/// `Secrets.example.plist` at the repo root shows its shape. Every value is
/// optional — without the file the app still builds and runs, it just starts
/// with an empty server field and no seeded API key, which is exactly what a
/// fresh clone should do.
enum Secrets {
    private static let values: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: String]
        else { return [:] }
        return dictionary
    }()

    /// Empty strings in the plist read as absent, so a half-filled file behaves
    /// the same as a missing one rather than seeding a blank key.
    private static func value(_ key: String) -> String? {
        guard let value = values[key], !value.isEmpty else { return nil }
        return value
    }

    static var defaultServerURL: String? { value("DefaultServerURL") }
    static var defaultProfile: String? { value("DefaultProfile") }
    static var seedAPIKey: String? { value("SeedAPIKey") }
}
