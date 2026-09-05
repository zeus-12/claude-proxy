import AppKit
import SwiftUI

private enum PopoverPage {
    case overview
    case claudeSettings
    case codexSettings
    case voiceSettings
    case claudeHelp
    case codexHelp
    case voiceHelp

    var title: String {
        switch self {
        case .overview: "LLM Proxy"
        case .claudeSettings: "Claude settings"
        case .codexSettings: "Codex settings"
        case .voiceSettings: "Voice settings"
        case .claudeHelp: "Claude API"
        case .codexHelp: "Codex API"
        case .voiceHelp: "Voice API"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var claude: ChatController
    @ObservedObject var codex: ChatController
    @EnvironmentObject private var voice: VoiceController
    @EnvironmentObject private var apiKey: APIKeyController
    @State private var page = PopoverPage.overview

    @ViewBuilder
    var body: some View {
        if page == .overview {
            overview
                .frame(width: 360)
                .fixedSize(horizontal: false, vertical: true)
                .background(PopoverBackdrop())
        } else {
            detailPage
                .frame(width: 360, height: 430)
                .background(PopoverBackdrop())
        }
    }

    private var overview: some View {
        VStack(spacing: 10) {
            chatCard(
                claude,
                settings: .claudeSettings,
                help: .claudeHelp
            )
            chatCard(
                codex,
                settings: .codexSettings,
                help: .codexHelp
            )
            EndpointCard(
                icon: "waveform",
                name: "Voice",
                subtitle: "Speech to text",
                url: voice.config.endpointURL,
                status: voice.status,
                isActive: voice.isEnabled,
                isAvailable: true,
                onToggle: voice.toggle,
                onSettings: { page = .voiceSettings },
                onHelp: { page = .voiceHelp }
            )
        }
        .padding(10)
    }

    private func chatCard(
        _ chat: ChatController,
        settings: PopoverPage,
        help: PopoverPage
    ) -> some View {
        EndpointCard(
            icon: chat.backend.icon,
            name: chat.backend.title,
            subtitle: chat.backend.subtitle,
            url: chat.config.baseURL,
            status: chat.status,
            isActive: chat.isEnabled,
            isAvailable: chat.isAvailable,
            onToggle: chat.toggle,
            onSettings: { page = settings },
            onHelp: { page = help }
        )
    }

    private var detailPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    page = .overview
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Back")
                .accessibilityLabel("Back to endpoints")

                Text(page.title)
                    .font(.body.weight(.semibold))
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.white.opacity(0.025))

            Divider()

            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailContent: some View {
        switch page {
        case .overview:
            EmptyView()
        case .claudeSettings:
            ChatSettingsPane(chat: claude)
        case .codexSettings:
            ChatSettingsPane(chat: codex)
        case .voiceSettings:
            VoiceSettingsPane()
        case .claudeHelp:
            APIReferencePane(section: APIDocs.chat(
                backend: .claude,
                baseURL: claude.config.baseURL,
                keyRequired: apiKey.isRequired(.claude)
            ))
        case .codexHelp:
            APIReferencePane(section: APIDocs.chat(
                backend: .codex,
                baseURL: codex.config.baseURL,
                keyRequired: apiKey.isRequired(.codex)
            ))
        case .voiceHelp:
            APIReferencePane(section: APIDocs.voice(
                endpointURL: voice.config.endpointURL,
                keyRequired: apiKey.isRequired(.voice)
            ))
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
    let onToggle: () -> Void
    let onSettings: () -> Void
    let onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 32, height: 32)
                    .background(
                        (isActive ? Color.accentColor : Color.white).opacity(isActive ? 0.14 : 0.055),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                .disabled(!isAvailable && !isActive)
            }

            if !isAvailable {
                message(
                    "\(name) is not installed or signed in.",
                    icon: "exclamationmark.triangle.fill",
                    color: .orange
                )
            } else if case .failed(let text) = status {
                message(text, icon: "xmark.circle.fill", color: .red)
            }

            HStack(spacing: 7) {
                StatusDot(status: status)
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
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
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.borderless)
                .help("Open \(name) settings")
                .accessibilityLabel("Open \(name) settings")
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075))
        }
    }

    private func message(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
