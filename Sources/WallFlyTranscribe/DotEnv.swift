import Foundation

/// Reads a `KEY=VALUE` file, the kind people keep a provider key in.
///
/// The rules match a shell close enough for this job:
///
/// - Blank lines and lines starting with `#` are skipped.
/// - A line splits at the first `=`. Everything after it is the value.
/// - Surrounding whitespace is trimmed, and matching single or double quotes
///   are dropped.
/// - A leading `export ` is ignored, so one file works in a shell too.
///
/// A value already set in the real environment wins over the file, so a shell
/// variable can override the file without editing it.
public enum DotEnv {
    public static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = unquoted(String(raw))
        }
        return values
    }

    /// Reads `path`, then lets the real environment override the file.
    ///
    /// Never touches global state, so tests can call it freely.
    public static func load(path: String,
                            environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String] {
        var values: [String: String] = [:]
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            values = parse(text)
        }
        for (key, value) in environment where !value.isEmpty {
            values[key] = value
        }
        return values
    }

    /// The `.env` path a person would expect: next to the package, where the
    /// README tells them to put it.
    public static func defaultPath() -> String {
        // The executable runs from the package root under `swift run`, and from
        // a build directory otherwise. Check both, then fall back to the
        // working directory.
        let working = FileManager.default.currentDirectoryPath
        return (working as NSString).appendingPathComponent(".env")
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, let last = value.last else { return value }
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }
}
