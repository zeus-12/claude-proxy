import Foundation

/// Framework-free unit checks for the voice logic, runnable with
/// `swift run ClaudeProxy --selftest` (or `./Scripts/dev.sh --selftest`).
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

        accumulator(check)
        framing(check)
        handshake(check)
        listenParams(check)
        clock(check)
        pcmConverter(check)
        deepgramMessages(check)

        print(failures == 0 ? "PASS — all checks passed" : "FAIL — \(failures) check(s) failed")
        return failures == 0
    }

    // MARK: - TranscriptAccumulator

    private static func accumulator(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — TranscriptAccumulator")
        func text(_ s: String) -> [String: Any] { ["type": "TranscriptText", "data": s] }
        let endpoint: [String: Any] = ["type": "TranscriptEndpoint"]

        // TranscriptText.data is cumulative within a segment.
        do {
            var a = TranscriptAccumulator()
            check("cumulative text (1)", a.handle(text("Hello")) == .segmentUpdated("Hello"))
            check("cumulative text (2)", a.handle(text("Hello world")) == .segmentUpdated("Hello world"))
            check("cumulative final", a.final == "Hello world")
        }

        // Endpoint finalizes a segment; the next segment appends.
        do {
            var a = TranscriptAccumulator()
            _ = a.handle(text("Hello world"))
            check("endpoint reports the settled segment",
                  a.handle(endpoint) == .segmentEnded("Hello world"))
            check("second segment starts fresh",
                  a.handle(text("how are you")) == .segmentUpdated("how are you"))
            check("interim spans segments", a.interim == "Hello world how are you")
            _ = a.handle(endpoint)
            check("multi-segment final", a.final == "Hello world how are you")
        }

        // Final transcript is trimmed.
        do {
            var a = TranscriptAccumulator()
            _ = a.handle(text("  spaced out  "))
            check("final is trimmed", a.final == "spaced out")
        }

        check("empty stream", TranscriptAccumulator().final == "")

        // Unknown / malformed messages are ignored.
        do {
            var a = TranscriptAccumulator()
            check("unknown type ignored", a.handle(["type": "SomethingElse"]) == nil)
            check("no type ignored", a.handle(["no_type": true]) == nil)
            _ = a.handle(text("kept"))
            check("missing data keeps current",
                  a.handle(["type": "TranscriptText"]) == .segmentUpdated("kept"))
            check("junk-safe final", a.final == "kept")
        }

        // Endpoint with nothing pending is a no-op (incl. duplicates).
        do {
            var a = TranscriptAccumulator()
            check("endpoint with nothing pending", a.handle(endpoint) == nil)
            _ = a.handle(text("first"))
            _ = a.handle(endpoint)
            check("duplicate endpoint", a.handle(endpoint) == nil)
            check("endpoint no-op", a.final == "first")
        }
    }

    // MARK: - WebSocket framing

    /// Builds a client-to-server frame, which RFC 6455 requires to be masked.
    private static func clientFrame(opcode: UInt8, payload: Data,
                                    isFinal: Bool = true,
                                    mask: [UInt8] = [0x12, 0x34, 0x56, 0x78]) -> Data {
        var out = Data()
        out.append((isFinal ? 0x80 : 0x00) | opcode)
        let count = payload.count
        if count < 126 {
            out.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            out.append(0x80 | 126)
            out.append(UInt8(count >> 8 & 0xFF))
            out.append(UInt8(count & 0xFF))
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8(UInt64(count) >> UInt64(shift) & 0xFF))
            }
        }
        out.append(contentsOf: mask)
        var masked = payload
        for i in masked.indices { masked[i] ^= mask[(i - masked.startIndex) % 4] }
        out.append(masked)
        return out
    }

    private static func framing(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — WebSocket framing")

        // A short text frame survives the round trip and the buffer is drained.
        do {
            var buffer = clientFrame(opcode: 0x1, payload: Data("hello".utf8))
            let frame = try? WebSocketFraming.decode(from: &buffer)
            check("text frame decodes",
                  frame?.payload == Data("hello".utf8) && frame?.opcode == .text)
            check("buffer fully consumed", buffer.isEmpty)
        }

        // 126-byte length path.
        do {
            let payload = Data(repeating: 0xAB, count: 300)
            var buffer = clientFrame(opcode: 0x2, payload: payload)
            let frame = try? WebSocketFraming.decode(from: &buffer)
            check("extended length decodes", frame?.payload == payload)
            check("extended length consumed", buffer.isEmpty)
        }

        // Two frames arriving in one read decode in order.
        do {
            var buffer = clientFrame(opcode: 0x1, payload: Data("one".utf8))
            buffer.append(clientFrame(opcode: 0x1, payload: Data("two".utf8)))
            let first = try? WebSocketFraming.decode(from: &buffer)
            let second = try? WebSocketFraming.decode(from: &buffer)
            check("first of two frames", first?.payload == Data("one".utf8))
            check("second of two frames", second?.payload == Data("two".utf8))
            check("both frames consumed", buffer.isEmpty)
        }

        // A partial frame yields nil and leaves the buffer untouched for retry.
        do {
            let whole = clientFrame(opcode: 0x1, payload: Data("hello".utf8))
            var buffer = whole.subdata(in: 0..<(whole.count - 2))
            let before = buffer
            let frame = try? WebSocketFraming.decode(from: &buffer)
            check("partial frame returns nil", frame == nil)
            check("partial frame leaves buffer intact", buffer == before)
        }

        // Unmasked client frames are a protocol violation.
        do {
            var buffer = WebSocketFraming.encode(opcode: .text, payload: Data("nope".utf8))
            var threw = false
            do { _ = try WebSocketFraming.decode(from: &buffer) } catch { threw = true }
            check("unmasked client frame rejected", threw)
        }

        // Control frames may not be fragmented.
        do {
            var buffer = clientFrame(opcode: 0x9, payload: Data(), isFinal: false)
            var threw = false
            do { _ = try WebSocketFraming.decode(from: &buffer) } catch { threw = true }
            check("fragmented control frame rejected", threw)
        }

        // Server frames are never masked, and carry FIN.
        do {
            let encoded = WebSocketFraming.encode(opcode: .binary, payload: Data([1, 2, 3]))
            check("server frame sets FIN", encoded[0] == 0x82)
            check("server frame is unmasked", encoded[1] & 0x80 == 0)
        }

        // Close frames carry a big-endian status code.
        do {
            let encoded = WebSocketFraming.close(code: 1008, reason: "")
            check("close frame opcode", encoded[0] == 0x88)
            check("close code big-endian",
                  encoded[2] == UInt8(1008 >> 8) && encoded[3] == UInt8(1008 & 0xFF))
        }
    }

    // MARK: - Handshake

    private static func handshake(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — WebSocket handshake")
        // The worked example from RFC 6455 §1.3.
        check("accept key matches the RFC vector",
              WebSocketHandshake.acceptKey(for: "dGhlIHNhbXBsZSBub25jZQ==")
                  == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")

        let upgrade = HTTPRequest.parse(Data("""
        GET /v1/listen?encoding=linear16 HTTP/1.1\r
        Host: 127.0.0.1:8765\r
        Upgrade: websocket\r
        Connection: Upgrade\r
        Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r
        Sec-WebSocket-Version: 13\r
        \r

        """.utf8))
        check("upgrade request parses", upgrade != nil)
        check("upgrade recognised", upgrade.map(WebSocketHandshake.isUpgrade) == true)

        let plain = HTTPRequest.parse(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        check("plain GET is not an upgrade", plain.map(WebSocketHandshake.isUpgrade) == false)
    }

    // MARK: - Listen params

    private static func listenParams(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — Deepgram listen params")

        let (path, query) = DeepgramListenParams.split(
            path: "/v1/listen?encoding=linear16&sample_rate=48000&channels=2&model=nova-3")
        check("path split", path == "/v1/listen")
        check("query parsed", query["sample_rate"] == "48000" && query["channels"] == "2")

        let parsed = try? DeepgramListenParams.parse(query: query)
        check("params parse", parsed?.sampleRate == 48000 && parsed?.channels == 2)
        check("model carried through", parsed?.model == "nova-3")

        // channels defaults to mono when the client omits it.
        let mono = try? DeepgramListenParams.parse(
            query: ["encoding": "linear16", "sample_rate": "16000"])
        check("channels defaults to 1", mono?.channels == 1)

        func rejects(_ query: [String: String], _ label: String) {
            var threw = false
            do { _ = try DeepgramListenParams.parse(query: query) } catch { threw = true }
            check(label, threw)
        }
        rejects(["sample_rate": "16000"], "missing encoding rejected")
        rejects(["encoding": "opus", "sample_rate": "16000"], "non-linear16 encoding rejected")
        rejects(["encoding": "linear16"], "missing sample_rate rejected")
        rejects(["encoding": "linear16", "sample_rate": "0"], "zero sample_rate rejected")
        rejects(["encoding": "linear16", "sample_rate": "16000", "channels": "0"],
                "zero channels rejected")

        // A path with no query is still usable.
        let (bare, empty) = DeepgramListenParams.split(path: "/listen")
        check("bare path splits", bare == "/listen" && empty.isEmpty)
    }

    // MARK: - Audio clock

    private static func clock(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — AudioClock")
        var clock = AudioClock()
        check("starts at zero", clock.position == 0)

        clock.advance(bytes: 32000)          // one second of 16 kHz mono linear16
        check("one second advanced", clock.position == 1.0)

        let first = clock.closeSegment()
        check("first segment spans 0…1", first.start == 0 && first.end == 1.0)

        clock.advance(bytes: 16000)          // half a second
        let second = clock.closeSegment()
        check("second segment starts where the first ended",
              second.start == 1.0 && second.end == 1.5)
        check("segment start tracks the close", clock.segmentStart == 1.5)
    }

    // MARK: - PCM conversion

    private static func pcm(_ samples: [Int16]) -> Data {
        samples.withUnsafeBytes { Data($0) }
    }

    private static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private static func pcmConverter(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — PCMConverter")

        check("zero sample rate rejected", PCMConverter(sourceRate: 0, channels: 1) == nil)
        check("zero channels rejected", PCMConverter(sourceRate: 16000, channels: 0) == nil)

        // 16 kHz mono is already the target: bytes pass through untouched.
        do {
            let converter = PCMConverter(sourceRate: 16000, channels: 1)
            check("16 kHz mono is passthrough", converter?.isPassthrough == true)
            let input = pcm([1, -2, 3, -4])
            check("passthrough returns the same bytes", converter?.convert(input) == input)
        }

        // A chunk that ends mid-sample stashes the odd byte and completes it on
        // the next chunk — a client may split a write between a sample's bytes.
        do {
            guard let converter = PCMConverter(sourceRate: 16000, channels: 1) else {
                check("residual converter builds", false); return
            }
            let first = converter.convert(Data([0x11, 0x22, 0x33]))   // 1 whole frame + 1 stray byte
            check("odd byte held back", first == Data([0x11, 0x22]))
            let second = converter.convert(Data([0x44]))              // completes the stashed frame
            check("stashed byte completed next chunk", second == Data([0x33, 0x44]))
        }

        // Stereo at the target rate needs no resampling, only a downmix: each
        // output sample is the average of the two input channels.
        do {
            let converter = PCMConverter(sourceRate: 16000, channels: 2)
            check("stereo is not passthrough", converter?.isPassthrough == false)
            let interleaved = pcm([100, 200, -400, 400])   // frames (100,200) and (-400,400)
            let mono = converter.flatMap { $0.convert(interleaved) }.map(samples)
            check("downmix averages the channels", mono == [150, 0])
        }

        // 32 kHz mono resamples to half the samples. AVAudioConverter holds a
        // variable number of samples back on any single call, so the count is
        // asserted over a stream of chunks driven through the one live converter
        // — which is also the cross-chunk behaviour that keeping it alive is for.
        // What stays buffered at the end is a fixed, small filter delay.
        do {
            let converter = PCMConverter(sourceRate: 32000, channels: 1)
            check("32 kHz mono is not passthrough", converter?.isPassthrough == false)
            let chunk = pcm(Array(repeating: 0, count: 3200))    // 0.1 s at 32 kHz
            var outSamples = 0
            for _ in 0..<10 { outSamples += (converter?.convert(chunk)?.count ?? 0) / 2 }
            check("resampled stream halves the sample count", abs(outSamples - 16000) < 64)
        }
    }

    // MARK: - Deepgram messages

    private static func decode(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func deepgramMessages(_ check: (String, Bool) -> Void) {
        print("VoiceSelfTest — Deepgram messages")

        let json = DeepgramProtocol.results(transcript: "Hello, there.",
                                            start: 1.0, end: 2.5,
                                            isFinal: true, speechFinal: true,
                                            fromFinalize: false, channels: 1,
                                            requestID: "req", modelUUID: "uuid")
        guard let message = decode(json) else {
            check("Results decodes as JSON", false)
            return
        }

        // Every field the consumer's schema declares without a default must be
        // present, or the whole message fails to deserialize and is dropped in
        // silence. This is the check that catches a regression there.
        let required = ["type", "start", "duration", "is_final", "speech_final",
                        "from_finalize", "channel_index", "channel", "metadata"]
        for key in required {
            check("Results has `\(key)`", message[key] != nil)
        }
        check("Results type", message["type"] as? String == "Results")
        check("duration derived from the span", message["duration"] as? Double == 1.5)

        let channel = message["channel"] as? [String: Any]
        let alternatives = channel?["alternatives"] as? [[String: Any]]
        let alternative = alternatives?.first
        check("alternative present", alternative != nil)
        check("transcript carried", alternative?["transcript"] as? String == "Hello, there.")
        check("alternative has confidence", alternative?["confidence"] != nil)

        // One word spanning the segment: the consumer builds its transcript from
        // `words`, so an empty array would silently render nothing.
        let words = alternative?["words"] as? [[String: Any]]
        check("exactly one word entry", words?.count == 1)
        check("word carries the whole segment", words?.first?["word"] as? String == "Hello, there.")
        check("word start matches segment", words?.first?["start"] as? Double == 1.0)
        check("word end matches segment", words?.first?["end"] as? Double == 2.5)
        for key in ["confidence", "speaker", "punctuated_word", "language"] {
            check("word has `\(key)`", words?.first?[key] != nil)
        }

        let metadata = message["metadata"] as? [String: Any]
        check("metadata request_id", metadata?["request_id"] as? String == "req")
        check("metadata model_uuid", metadata?["model_uuid"] as? String == "uuid")
        let modelInfo = metadata?["model_info"] as? [String: Any]
        for key in ["name", "version", "arch"] {
            check("model_info has `\(key)`", modelInfo?[key] != nil)
        }

        // An empty transcript must not claim a word.
        let emptyJSON = DeepgramProtocol.results(transcript: "", start: 0, end: 0,
                                                 isFinal: false, speechFinal: false,
                                                 fromFinalize: false, channels: 1,
                                                 requestID: "req", modelUUID: "uuid")
        let emptyAlternative = ((decode(emptyJSON)?["channel"] as? [String: Any])?["alternatives"]
            as? [[String: Any]])?.first
        check("empty transcript yields no words",
              (emptyAlternative?["words"] as? [[String: Any]])?.isEmpty == true)

        // Terminal and utterance-end shapes.
        let terminal = decode(DeepgramProtocol.terminal(requestID: "req", duration: 9.5,
                                                        channels: 1, created: "now"))
        check("Metadata type", terminal?["type"] as? String == "Metadata")
        for key in ["request_id", "created", "duration", "channels"] {
            check("Metadata has `\(key)`", terminal?[key] != nil)
        }

        let utterance = decode(DeepgramProtocol.utteranceEnd(lastWordEnd: 2.5, channels: 1))
        check("UtteranceEnd type", utterance?["type"] as? String == "UtteranceEnd")
        check("UtteranceEnd last_word_end", utterance?["last_word_end"] as? Double == 2.5)

        let error = decode(DeepgramProtocol.error("boom"))
        check("Error type", error?["type"] as? String == "Error")
        check("Error message", error?["error_message"] as? String == "boom")
        check("Error has error_code", error?["error_code"] != nil)
        check("Error has provider", error?["provider"] != nil)
    }
}
