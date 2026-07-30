import SwiftUI
import AppKit
import Observation

/// Pasteboard write plus the "just copied" flash that every copy button shows.
/// `copied` is driven by `setString`'s return value, not by the click — a failed
/// write leaves the button unchanged rather than claiming success.
@MainActor
@Observable
final class CopyFlash {
    private(set) var copied = false
    @ObservationIgnored private var reset: Task<Void, Never>?

    func copy(_ value: @autoclosure () -> String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(value(), forType: .string) else { return }
        copied = true
        reset?.cancel()
        reset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.copied = false
        }
    }
}

/// The document/checkmark pair, morphing between the two. Inherits its colour
/// from the surrounding button so neither state is tinted.
private struct CopyFlashIcon: View {
    let copied: Bool

    var body: some View {
        ZStack {
            if copied {
                Image(systemName: "checkmark").transition(.blurReplace)
            } else {
                Image(systemName: "doc.on.doc").transition(.blurReplace)
            }
        }
    }
}

private let copyFlashSpring = Animation.spring(response: 0.34, dampingFraction: 0.6)

/// A borderless button that copies a string to the pasteboard.
struct CopyButton: View {
    let value: String
    init(_ value: String) { self.value = value }

    @State private var flash = CopyFlash()

    var body: some View {
        Button {
            flash.copy(value)
        } label: {
            CopyFlashIcon(copied: flash.copied)
                .font(.caption)
                .frame(width: 14, height: 14)
                .background {
                    Circle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 21, height: 21)
                        .scaleEffect(flash.copied ? 1 : 0.3)
                        .opacity(flash.copied ? 1 : 0)
                }
                .scaleEffect(flash.copied ? 1.1 : 1)
        }
        .buttonStyle(.borderless)
        .animation(copyFlashSpring, value: flash.copied)
        .help(flash.copied ? "Copied" : "Copy")
    }
}

/// A labelled button that copies a block of documentation to the pasteboard.
struct CopyDocsButton: View {
    let title: String
    /// Built lazily: the docs are only serialized when the user actually clicks.
    let markdown: () -> String

    @State private var flash = CopyFlash()

    var body: some View {
        Button {
            flash.copy(markdown())
        } label: {
            HStack(spacing: 6) {
                CopyFlashIcon(copied: flash.copied)
                Text(flash.copied ? "Copied" : title)
                    .contentTransition(.opacity)
            }
        }
        .animation(copyFlashSpring, value: flash.copied)
        .help("Copy this reference as Markdown — paste it into an LLM or your notes")
    }
}

/// A small dot reflecting the *real* endpoint status — green (up), yellow
/// (starting), red (failed), gray (stopped). Never optimistic.
struct StatusDot: View {
    let status: InstanceStatus
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch status {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

/// Dot + text describing an endpoint's live status (with the error message when
/// it failed).
struct EndpointStatusLabel: View {
    let status: InstanceStatus
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(status: status)
            Text(text).foregroundStyle(.secondary)
        }
    }
    private var text: String {
        switch status {
        case .running: return "Running"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .failed(let m): return m
        }
    }
}
