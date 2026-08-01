import Foundation

/// Framework-free unit checks for request decoding and prompt building, runnable
/// with `swift run ClaudeProxy --selftest`. Same rationale as `VoiceSelfTest`:
/// `swift test` needs full Xcode, which the build machine doesn't have.
enum ProxySelfTest {

    /// 1×1 transparent PNG.
    private static let pngBase64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    static func run() -> Bool {
        var failures = 0
        func check(_ label: String, _ condition: Bool) {
            if condition { print("  ✓ \(label)") }
            else { print("  ✗ \(label)"); failures += 1 }
        }

        func decode(_ json: String) throws -> ChatCompletionRequest {
            try JSONDecoder().decode(ChatCompletionRequest.self, from: Data(json.utf8))
        }
        /// The client-facing 400 message, or nil if the request decoded.
        func rejection(_ json: String) -> String? {
            do {
                let request = try decode(json)
                try request.validate()
                return nil
            } catch let e as ProxyRequestError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        func blocks(_ json: String) -> [ClaudeBackend.PromptBlock] {
            guard let request = try? decode(json) else { return [] }
            return ClaudeBackend.buildPrompt(request.messages).blocks
        }
        func image(_ block: ClaudeBackend.PromptBlock) -> ImageBlock? {
            if case .image(let i) = block { return i } else { return nil }
        }
        func envelope(_ parts: String) -> String {
            #"{"model":"sonnet","messages":[{"role":"user","content":[\#(parts)]}]}"#
        }
        let textPart = #"{"type":"text","text":"hi"}"#
        let openAIImage = #"{"type":"image_url","image_url":{"url":"data:image/png;base64,\#(pngBase64)"}}"#

        print("ProxySelfTest — content parts")

        // Every spelling of an image part decodes to the same block.
        do {
            let expected = try? ImageBlock(mediaType: "image/png", base64: pngBase64)
            let spellings = [
                "OpenAI image_url object": openAIImage,
                "OpenAI image_url bare string": #"{"type":"image_url","image_url":"data:image/png;base64,\#(pngBase64)"}"#,
                "Anthropic image/source": #"{"type":"image","source":{"type":"base64","media_type":"image/png","data":"\#(pngBase64)"}}"#,
                "Responses input_image": #"{"type":"input_image","image_url":"data:image/png;base64,\#(pngBase64)"}"#,
            ]
            for (name, part) in spellings {
                let b = blocks(envelope(part))
                check(name, b.count == 1 && image(b[0]) == expected)
            }
        }

        // Interleaved parts keep their order — image N must stay with label N.
        do {
            let b = blocks(envelope([
                #"{"type":"text","text":"[Image 1 of 2]"}"#, openAIImage,
                #"{"type":"text","text":"[Image 2 of 2]"}"#, openAIImage,
            ].joined(separator: ",")))
            check("interleaved order preserved",
                  b.count == 4 && b[0] == .text("[Image 1 of 2]") && image(b[1]) != nil
                               && b[2] == .text("[Image 2 of 2]") && image(b[3]) != nil)
        }

        // Text-only requests still collapse to exactly one block.
        do {
            let single = blocks(#"{"model":"sonnet","messages":[{"role":"user","content":"Hello!"}]}"#)
            check("plain string → one text block", single == [.text("Hello!")])

            let parts = blocks(envelope(#"{"type":"text","text":"a"},{"type":"text","text":"b"}"#))
            check("adjacent text parts merge", parts == [.text("ab")])

            let multi = blocks("""
            {"model":"sonnet","messages":[
              {"role":"system","content":"sys"},
              {"role":"user","content":"one"},
              {"role":"assistant","content":"two"},
              {"role":"user","content":"three"}]}
            """)
            check("multi-turn transcript unchanged",
                  multi == [.text("User: one\n\nAssistant: two\n\nUser: three\n\nAssistant:")])
        }

        // Images survive a multi-turn transcript, in place.
        do {
            let b = blocks("""
            {"model":"sonnet","messages":[
              {"role":"user","content":[\(textPart),\(openAIImage)]},
              {"role":"assistant","content":"ok"}]}
            """)
            check("image kept inside transcript",
                  b.count == 3 && b[0] == .text("User: hi") && image(b[1]) != nil
                               && b[2] == .text("\n\nAssistant: ok\n\nAssistant:"))
        }

        print("ProxySelfTest — rejections")

        // An image we cannot forward is a 400, never a silent drop.
        check("unsupported media type",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/tiff;base64,\#(pngBase64)"}}"#))?
                .contains("image/tiff") == true)
        check("invalid base64",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/png;base64,!!!!"}}"#))?
                .contains("valid base64") == true)
        check("data URL without base64 marker",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"data:image/png,abc"}}"#))?
                .contains("base64-encoded") == true)
        check("non-http scheme",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"file:///etc/passwd"}}"#))?
                .contains("http(s)") == true)
        check("image part missing image_url",
              rejection(envelope(#"{"type":"image_url"}"#))?.contains("missing `image_url`") == true)
        check("unknown part type",
              rejection(envelope(#"{"type":"input_audio","input_audio":{}}"#))?
                .contains("input_audio") == true)
        check("text-only request still accepted",
              rejection(envelope(textPart)) == nil)
        check("http URL accepted",
              rejection(envelope(#"{"type":"image_url","image_url":{"url":"https://example.com/x.png"}}"#)) == nil)

        print("ProxySelfTest — stdin frames")

        // The CLI reads one JSON object per line; images ride in the user frame.
        do {
            let png = try? ImageBlock(mediaType: "image/png", base64: pngBase64)
            let data = try? ClaudeBackend.stdinFrames([.text("look"), .image(png!)])
            let lines = String(data: data ?? Data(), encoding: .utf8)?
                .split(separator: "\n", omittingEmptySubsequences: false) ?? []
            check("two frames, trailing newline", lines.count == 3 && lines[2].isEmpty)

            let first = lines.first.flatMap { jsonObject(String($0)) }
            check("frame 1 is the initialize handshake",
                  first?["type"] as? String == "control_request")

            let user = lines.count > 1 ? jsonObject(String(lines[1])) : nil
            let content = ((user?["message"] as? [String: Any])?["content"]) as? [[String: Any]] ?? []
            check("frame 2 is the user turn", user?["type"] as? String == "user")
            check("blocks keep order in the frame",
                  content.count == 2 && content[0]["type"] as? String == "text"
                                     && content[1]["type"] as? String == "image")
            let source = content.count > 1 ? content[1]["source"] as? [String: Any] : nil
            check("image source is base64 + media type",
                  source?["type"] as? String == "base64"
                  && source?["media_type"] as? String == "image/png"
                  && source?["data"] as? String == pngBase64)

            // Blank text blocks would be rejected upstream.
            let blank = try? ClaudeBackend.stdinFrames([.text("  \n "), .image(png!)])
            let blankUser = String(data: blank ?? Data(), encoding: .utf8)?
                .split(separator: "\n").dropFirst().first.flatMap { jsonObject(String($0)) }
            let blankContent = ((blankUser?["message"] as? [String: Any])?["content"]) as? [[String: Any]] ?? []
            check("blank text block dropped",
                  blankContent.count == 1 && blankContent[0]["type"] as? String == "image")
        }

        print("ProxySelfTest — permission configuration")

        // The live suite proves these hold against the real CLI; these catch a
        // rule being dropped or mistyped without waiting on a network run.
        do {
            let settings = ClaudeBackend.permissionSettings
            let parsed = jsonObject(settings)?["permissions"] as? [String: Any]
            let deny = parsed?["deny"] as? [String] ?? []
            let allow = parsed?["allow"] as? [String] ?? []

            check("settings are valid JSON", parsed != nil)
            // All three globs are needed: //** absolute, ~/** home, ** cwd.
            check("denies absolute reads", deny.contains("Read(//**)"))
            check("denies home reads", deny.contains("Read(~/**)"))
            check("denies relative reads", deny.contains("Read(**)"))
            check("denies loopback fetch", deny.contains("WebFetch(domain:127.0.0.1)"))
            check("denies localhost fetch", deny.contains("WebFetch(domain:localhost)"))
            check("denies link-local fetch", deny.contains("WebFetch(domain:169.254.169.254)"))
            check("allows WebFetch", allow == ["WebFetch"])
            check("WebFetch is the only tool", ClaudeBackend.allowedTools == ["WebFetch"])
        }

        print("ProxySelfTest — message text is forwarded verbatim")

        // File reads are denied at the CLI's permission layer, so message text
        // needs no rewriting. These guard against a rewrite creeping back in.
        do {
            for text in ["read @/etc/hosts now", "@~/.ssh/id_rsa", "mail bob@example.com",
                         "@../../etc/hosts", "cc @vishnu please", "/usr is a directory",
                         "/caveman hello"] {
                let framed = try? ClaudeBackend.stdinFrames([.text(text)])
                let userLine = String(data: framed ?? Data(), encoding: .utf8)?
                    .split(separator: "\n").dropFirst().first
                let content = ((userLine.flatMap { jsonObject(String($0)) }?["message"]
                                as? [String: Any])?["content"]) as? [[String: Any]] ?? []
                check("verbatim: \(text)", content.first?["text"] as? String == text)
            }
        }

        print(failures == 0 ? "PASS — all checks passed" : "FAIL — \(failures) check(s) failed")
        return failures == 0
    }

    private static func jsonObject(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
