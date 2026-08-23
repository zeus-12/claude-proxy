import Foundation

/// Common result shape for either local coding client. The HTTP layer does not
/// need to know which subprocess produced the assistant text.
struct ChatStreamResult {
    let deltas: AsyncThrowingStream<String, Error>
}
