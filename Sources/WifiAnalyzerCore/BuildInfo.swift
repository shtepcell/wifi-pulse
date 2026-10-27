import Foundation

public enum BuildInfo {
    /// Shared by the CLI, session metadata, and the app bundle build script.
    public static let version: String = {
        guard let url = Bundle.module.url(forResource: "VERSION", withExtension: nil),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("The version resource is missing. Rebuild the application bundle.")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}
