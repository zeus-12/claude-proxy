import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var claude: ChatController
    @ObservedObject var codex: ChatController
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var apiKey: APIKeyController

    let onOpenSettings: (SettingsTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(spacing: 10) {
                    chatCard(
                        claude,
                        settings: .claude,
                        help: .claudeHelp
                    )
                    chatCard(
                        codex,
                        settings: .codex,
                        help: .codexHelp
                    )
                    EndpointCard(
                        icon: "waveform",
                        name: "Voice",
                        subtitle: "Speech-to-text WebSocket",
                        url: voice.config.endpointURL,
                        status: voice.status,
                        isActive: voice.isActive,
                        isAvailable: true,
                        isConfigured: apiKey.isConfigured(.voice),
                        onToggle: voice.toggle,
                        onSettings: { onOpenSettings(.voice) },
                        onHelp: { onOpenSettings(.voiceHelp) }
                    )
                }
                .padding(12)
            }

            Divider()
            footer
        }
        .frame(width: 400, height: 500)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 1) {
                Text("LLM Proxy").font(.headline)
                Text("Local endpoints for your subscriptions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                onOpenSettings(.claude)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Text(runningSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit LLM Proxy") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func chatCard(
        _ chat: ChatController,
        settings: SettingsTab,
        help: SettingsTab
    ) -> some View {
        EndpointCard(
            icon: chat.backend.icon,
            name: chat.backend.title,
            subtitle: chat.backend.subtitle,
            url: chat.config.baseURL,
            status: chat.status,
            isActive: chat.isActive,
            isAvailable: chat.isAvailable,
            isConfigured: apiKey.isConfigured(chat.backend.keyScope),
            onToggle: chat.toggle,
            onSettings: { onOpenSettings(settings) },
            onHelp: { onOpenSettings(help) }
        )
    }

    private var runningSummary: String {
        let count = (claude.isActive ? 1 : 0)
            + (codex.isActive ? 1 : 0)
            + (voice.isActive ? 1 : 0)
        switch count {
        case 0: return "No endpoints running"
        case 1: return "1 endpoint running"
        default: return "\(count) endpoints running"
        }
    }
}

private struct EndpointCard: View {
    let icon: String
    let name: String
    let subtitle: String
    let url: String
    let status: InstanceStatus
    let isActive: Bool
    let isAvailable: Bool
    let isConfigured: Bool
    let onToggle: () -> Void
    let onSettings: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 30, height: 30)
                    .background(
                        (isActive ? Color.accentColor : Color.secondary).opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 9)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "Run \(name) endpoint",
                    isOn: Binding(get: { isActive }, set: { _ in onToggle() })
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel("Run \(name) endpoint")
                .disabled(!isConfigured || (!isAvailable && !isActive))
            }

            if !isAvailable {
                message(
                    "\(name) is not installed or signed in.",
                    icon: "exclamationmark.triangle.fill",
                    color: .orange
                )
            } else if !isConfigured {
                HStack(spacing: 7) {
                    message(
                        "Set an access key before starting.",
                        icon: "key.fill",
                        color: .orange
                    )
                    Spacer()
                    Button("Set up", action: onSettings)
                        .controlSize(.small)
                }
            } else if case .failed(let text) = status {
                message(text, icon: "xmark.circle.fill", color: .red)
            }

            HStack(spacing: 7) {
                StatusDot(status: status)
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                CopyButton(url)
                Spacer()

                Button(action: onHelp) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.borderless)
                .help("Open \(name) API help")
                .accessibilityLabel("Open \(name) API help")

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("Open \(name) settings")
                .accessibilityLabel("Open \(name) settings")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .strokeBorder(Color.primary.opacity(0.07))
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
