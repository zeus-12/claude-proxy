import Foundation

/// A minimal Deepgram-protocol client used to exercise the voice endpoint
/// end-to-end against the real Claude speech-to-text backend, driven from
/// `--voice-client`. It connects to a running `--voice-server`, streams a raw
/// linear16 PCM file at real time, and prints the transcripts that come back.
///
/// Audio is paced to real time on purpose: the upstream processes at roughly
/// real time and drops whatever it has not reached when the stream closes, so a
/// file pushed faster than real time transcribes only its opening.
enum VoiceLiveClient {

    /// Streams `pcmPath` (raw interleaved Int16 at the rate/channels declared in
    /// `url`'s query) to `url` and prints results. Returns true if at least one
    /// final transcript came back.
    static func run(url urlString: String, pcmPath: String) -> Bool {
        guard let url = URL(string: urlString) else {
            print("invalid url: \(urlString)"); return false
        }
        guard let audio = FileManager.default.contents(atPath: pcmPath), !audio.isEmpty else {
            print("could not read PCM file: \(pcmPath)"); return false
        }

        let (rate, channels) = format(from: url)
        let frameBytes = 2 * channels
        let bytesPer20ms = max(frameBytes, Int(rate / 50) * frameBytes)
        print("streaming \(audio.count) bytes at \(Int(rate)) Hz / \(channels) ch "
              + "(\(bytesPer20ms) bytes per 20 ms)")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        let done = DispatchSemaphore(value: 0)
        var finals: [String] = []

        func receive() {
            task.receive { result in
                switch result {
                case .failure:
                    done.signal()
                case .success(let message):
                    if case .string(let text) = message, let final = Self.finalTranscript(text) {
                        print("  FINAL  \"\(final)\"")
                        finals.append(final)
                    } else if case .string(let text) = message, Self.isTerminal(text) {
                        print("  (metadata — stream closed)")
                        done.signal()
                        return
                    }
                    receive()
                }
            }
        }

        task.resume()
        receive()

        Task {
            var offset = audio.startIndex
            while offset < audio.endIndex {
                let end = min(offset + bytesPer20ms, audio.endIndex)
                try? await task.send(.data(audio.subdata(in: offset..<end)))
                offset = end
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await task.send(.string(#"{"type":"CloseStream"}"#))
        }

        // The upstream keeps processing briefly after the last chunk; the
        // terminal Metadata (or a socket close) signals done sooner if it wins.
        let timeout = DispatchTime.now() + .seconds(Int(audio.count / max(frameBytes, 1)) / Int(rate) + 30)
        _ = done.wait(timeout: timeout)
        task.cancel(with: .goingAway, reason: nil)

        let transcript = finals.joined(separator: " ")
        print(transcript.isEmpty ? "no transcript returned" : "\ntranscript: \(transcript)")
        return !transcript.isEmpty
    }

    private static func format(from url: URL) -> (rate: Double, channels: Int) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let rate = items.first { $0.name == "sample_rate" }?.value.flatMap(Double.init) ?? 16000
        let channels = items.first { $0.name == "channels" }?.value.flatMap(Int.init) ?? 1
        return (rate, max(channels, 1))
    }

    private static func object(_ text: String) -> [String: Any]? {
        text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// The settled transcript of a final `Results` message, or nil for interim
    /// results and every other message type.
    private static func finalTranscript(_ text: String) -> String? {
        guard let object = object(text),
              object["type"] as? String == "Results",
              object["is_final"] as? Bool == true,
              let channel = object["channel"] as? [String: Any],
              let alternatives = channel["alternatives"] as? [[String: Any]],
              let transcript = alternatives.first?["transcript"] as? String,
              !transcript.isEmpty else { return nil }
        return transcript
    }

    private static func isTerminal(_ text: String) -> Bool {
        object(text)?["type"] as? String == "Metadata"
    }
}
