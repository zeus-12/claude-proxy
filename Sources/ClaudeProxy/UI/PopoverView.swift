import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var chat: ChatController
    @EnvironmentObject var voice: VoiceController
    @State private var route: Route = .home

    /// In-popover navigation — edit and the API reference live right here, no
    /// separate window.
    enum Route: Equatable {
        case home, editChat, editVoice, reference
    }

    var body: some View {
        VStack(spacing: 0) {
            switch route {
            case .home:
                home
            case .editChat:
                subPage("Chat") { ChatSettingsPane() }
            case .editVoice:
                subPage("Voice") { VoiceSettingsPane() }
            case .reference:
                subPage("API Reference") { APIReferencePane() }
            }
        }
        .frame(width: 360, height: 440)
    }

    // MARK: - Home

    private var home: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !chat.claudeAvailable {
                warningBanner
            }

            ScrollView {
                VStack(spacing: 10) {
                    EndpointCard(
                        icon: "bubble.left.and.text.bubble.right",
                        name: "Chat",
                        subtitle: "OpenAI-compatible chat API",
                        url: chat.config.baseURL,
                        status: chat.status,
                        isActive: chat.isActive,
                        onToggle: { chat.toggle() },
                        onEdit: { route = .editChat }
                    )
                    EndpointCard(
                        icon: "waveform",
                        name: "Voice",
                        subtitle: "Speech-to-text WebSocket",
                        url: voice.config.endpointURL,
                        status: voice.status,
                        isActive: voice.isActive,
                        onToggle: { voice.toggle() },
                        onEdit: { route = .editVoice }
                    )
                }
                .padding(12)
            }

            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
            Text("Claude Proxy").font(.headline)
            Spacer()
            Button { route = .reference } label: {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .help("API reference — what each endpoint expects")
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Text("\(runningCount) of 2 running")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
        .padding(12)
    }

    private var warningBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("`claude` CLI not found on your login PATH. Install Claude Code and log in.")
                .font(.caption)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var runningCount: Int {
        (chat.isActive ? 1 : 0) + (voice.isActive ? 1 : 0)
    }

    // MARK: - Sub-page (edit / reference) with a back bar

    private func subPage<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { route = .home } label: {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(title).font(.headline)
                Spacer()
                // Balances the back button so the title stays centered.
                Image(systemName: "chevron.left").opacity(0)
                Text("Back").opacity(0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            content()
        }
    }
}

/// A single endpoint row, used identically for Chat and Voice so they look the
/// same. Toggle reflects the real running state; there is no delete — these are
/// fixed, built-in endpoints.
private struct EndpointCard: View {
    let icon: String
    let name: String
    let subtitle: String
    let url: String
    let status: InstanceStatus
    let isActive: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(isActive ? Color.accentColor : Color.secondary.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(.body, design: .rounded)).bold()
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(get: { isActive }, set: { _ in onToggle() }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            if case .failed(let message) = status {
                Text(message).font(.caption2).foregroundStyle(.red)
            }

            HStack(spacing: 6) {
                StatusDot(status: status)
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                CopyButton(url)
                Spacer()
                Button(action: onEdit) {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
