import Foundation

/// A parsed HTTP/1.1 request. We support exactly what OpenAI-style clients send:
/// a request line, headers, and an optional `Content-Length`-delimited body.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]   // lowercased keys
    let body: Data?

    /// Parse a request from accumulated bytes. Returns nil if more data is
    /// needed (headers incomplete, or body shorter than Content-Length).
    static func parse(_ data: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return nil }

        let headerData = data.subdata(in: data.startIndex..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let available = data.subdata(in: bodyStart..<data.endIndex)

        if let lengthString = headers["content-length"], let length = Int(lengthString), length > 0 {
            // Wait until the full body has arrived.
            guard available.count >= length else { return nil }
            return HTTPRequest(method: method, path: path, headers: headers,
                               body: available.subdata(in: available.startIndex..<available.index(available.startIndex, offsetBy: length)))
        }

        return HTTPRequest(method: method, path: path, headers: headers, body: available.isEmpty ? nil : available)
    }
}
