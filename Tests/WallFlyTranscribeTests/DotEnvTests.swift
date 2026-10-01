import Foundation
import Testing
@testable import WallFlyTranscribe

@Suite("Reading a .env file")
struct DotEnvTests {
    @Test("reads simple pairs")
    func readsSimplePairs() {
        let parsed = DotEnv.parse("SPEECHMATICS_API_KEY=abc123\nOTHER=42")
        #expect(parsed == ["SPEECHMATICS_API_KEY": "abc123", "OTHER": "42"])
    }

    @Test("skips blank lines and comments")
    func skipsBlanksAndComments() {
        let text = """
        # a comment

        KEY=value

          # indented comment
        """
        #expect(DotEnv.parse(text) == ["KEY": "value"])
    }

    @Test("trims space and drops matching quotes")
    func trimsAndUnquotes() {
        let text = """
          SPACED = "quoted value"
        SINGLE='single value'
        BARE=no quotes
        """
        #expect(DotEnv.parse(text) == [
            "SPACED": "quoted value",
            "SINGLE": "single value",
            "BARE": "no quotes",
        ])
    }

    @Test("splits on the first equals only")
    func splitsOnFirstEquals() {
        // A value can hold an equals sign, which is how long URLs are written.
        #expect(DotEnv.parse("URL=https://example.com/?a=1&b=2")
                == ["URL": "https://example.com/?a=1&b=2"])
    }

    @Test("accepts a shell export prefix")
    func acceptsExportPrefix() {
        #expect(DotEnv.parse("export KEY=value") == ["KEY": "value"])
    }

    @Test("keeps an empty value empty")
    func keepsEmptyValue() {
        #expect(DotEnv.parse("SPEECHMATICS_API_KEY=") == ["SPEECHMATICS_API_KEY": ""])
    }

    @Test("lets the real environment override the file")
    func environmentWins() throws {
        let path = NSTemporaryDirectory() + "wallfly-env-\(UUID().uuidString)"
        try "SPEECHMATICS_API_KEY=from-file\nOTHER=x".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let values = DotEnv.load(path: path, environment: ["SPEECHMATICS_API_KEY": "from-shell"])
        #expect(values["SPEECHMATICS_API_KEY"] == "from-shell")
        #expect(values["OTHER"] == "x")
    }

    @Test("treats a missing file as empty, not as an error")
    func missingFileIsFine() {
        let values = DotEnv.load(path: "/nonexistent/\(UUID().uuidString)",
                                 environment: ["SPEECHMATICS_API_KEY": "from-shell"])
        #expect(values["SPEECHMATICS_API_KEY"] == "from-shell")
    }
}
