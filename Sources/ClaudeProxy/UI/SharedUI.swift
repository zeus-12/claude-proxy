import SwiftUI
import AppKit

/// A borderless button that copies a string to the pasteboard.
struct CopyButton: View {
    let value: String
    init(_ value: String) { self.value = value }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc").font(.caption)
        }
        .buttonStyle(.borderless)
        .help("Copy")
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
