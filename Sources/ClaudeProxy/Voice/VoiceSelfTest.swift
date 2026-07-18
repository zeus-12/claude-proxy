import Foundation

/// Framework-free unit checks for the voice-to-text accumulation logic, runnable
/// with `swift run ClaudeProxy --selftest` (or `./Scripts/dev.sh --selftest`).
///
/// Why not XCTest/swift-testing: both require full Xcode, which the build machine
/// doesn't have, so `swift test` can't run here. This runs anywhere the app
/// builds and exits non-zero on failure, so it works locally and in CI.
enum VoiceSelfTest {

    /// Runs all checks. Returns true if everything passed.
    static func run() -> Bool {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            if condition { print("  ✓ \(label)") }
            else { print("  ✗ \(label)"); failures += 1 }
        }
        func text(_ s: String) -> [String: Any] { ["type": "TranscriptText", "data": s] }
        let endpoint: [String: Any] = ["type": "TranscriptEndpoint"]

        print("VoiceSelfTest — TranscriptAccumulator")

        // TranscriptText.data is cumulative within a segment.
        do {
            var a = TranscriptAccumulator()
            check("cumulative text (1)", a.handle(text("Hello")) == "Hello")
            check("cumulative text (2)", a.handle(text("Hello world")) == "Hello world")
            check("cumulative final", a.final == "Hello world")
        }

        // Endpoint finalizes a segment; the next segment appends.
        do {
            var a = TranscriptAccumulator()
            _ = a.handle(text("Hello world"))
            _ = a.handle(endpoint)
            check("second segment appends", a.handle(text("how are you")) == "Hello world how are you")
            _ = a.handle(endpoint)
            check("multi-segment final", a.final == "Hello world how are you")
        }

        // Final transcript is trimmed.
        do {
            var a = TranscriptAccumulator()
            _ = a.handle(text("  spaced out  "))
            check("final is trimmed", a.final == "spaced out")
        }

        // Empty stream → empty transcript.
        check("empty stream", TranscriptAccumulator().final == "")

        // Unknown / malformed messages are ignored.
        do {
            var a = TranscriptAccumulator()
            check("unknown type ignored", a.handle(["type": "SomethingElse"]) == nil)
            check("no type ignored", a.handle(["no_type": true]) == nil)
            _ = a.handle(text("kept"))
            check("missing data keeps current", a.handle(["type": "TranscriptText"]) == "kept")
            check("junk-safe final", a.final == "kept")
        }

        // Endpoint with nothing pending is a no-op (incl. duplicates).
        do {
            var a = TranscriptAccumulator()
            _ = a.handle(endpoint)
            _ = a.handle(text("first"))
            _ = a.handle(endpoint)
            _ = a.handle(endpoint)
            check("endpoint no-op", a.final == "first")
        }

        print(failures == 0 ? "PASS — all checks passed" : "FAIL — \(failures) check(s) failed")
        return failures == 0
    }
}
