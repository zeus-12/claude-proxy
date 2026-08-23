import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var claude: ChatController
    @ObservedObject var codex: ChatController
    @EnvironmentObject var voice: VoiceController
    @State private var route: Route = .home

    enum Route: Equatable {
        case home, editClaude, editCodex, editVoice, helpClaude, helpCodex, helpVoice
    }

    var body: some View {
        VStack(spacing: 0) {
            switch route {
            case .home: home
            case .editClaude: subPage("Claude settings") { ChatSettingsPane(chat: claude) }
            case .editCodex: subPage("Codex settings") { ChatSettingsPane(chat: codex) }
            case .editVoice: subPage("Voice settings") { VoiceSettingsPane() }
            case .helpClaude: subPage("Claude help") { APIReferencePane(section: APIDocs.chat(backend: .claude, baseURL: claude.config.baseURL)) }
            case .helpCodex: subPage("Codex help") { APIReferencePane(section: APIDocs.chat(backend: .codex, baseURL: codex.config.baseURL)) }
            case .helpVoice: subPage("Voice help") { APIReferencePane(section: APIDocs.voice(endpointURL: voice.config.endpointURL)) }
            }
        }.frame(width: 380, height: 520)
    }

    private var home: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                VStack(alignment: .leading, spacing: 0) {
                    Text("LLM Proxy").font(.headline)
                    Text("Independent local endpoints").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(12)
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    chatCard(claude, settings: .editClaude, help: .helpClaude)
                    chatCard(codex, settings: .editCodex, help: .helpCodex)
                    EndpointCard(icon: "waveform", name: "Voice", subtitle: "Speech-to-text WebSocket",
                                 url: voice.config.endpointURL, status: voice.status, isActive: voice.isActive,
                                 isAvailable: true, onToggle: voice.toggle,
                                 onSettings: { route = .editVoice }, onHelp: { route = .helpVoice })
                }.padding(12)
            }
            Divider()
            HStack {
                Text("\(runningCount) of 3 running").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless).font(.caption)
            }.padding(12)
        }
    }

    private func chatCard(_ chat: ChatController, settings: Route, help: Route) -> some View {
        EndpointCard(icon: chat.backend.icon, name: chat.backend.title,
                     subtitle: "Chat · \(chat.backend.subtitle)", url: chat.config.baseURL,
                     status: chat.status, isActive: chat.isActive, isAvailable: chat.isAvailable,
                     onToggle: chat.toggle, onSettings: { route = settings }, onHelp: { route = help })
    }

    private var runningCount: Int {
        (claude.isActive ? 1 : 0) + (codex.isActive ? 1 : 0) + (voice.isActive ? 1 : 0)
    }

    private func subPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { route = .home } label: { Image(systemName: "chevron.left"); Text("Back") }
                    .buttonStyle(.borderless)
                Spacer(); Text(title).font(.headline); Spacer()
                Image(systemName: "chevron.left").opacity(0); Text("Back").opacity(0)
            }.padding(.horizontal, 12).padding(.vertical, 10)
            Divider(); content()
        }
    }
}

private struct EndpointCard: View {
    let icon: String, name: String, subtitle: String, url: String
    let status: InstanceStatus
    let isActive: Bool, isAvailable: Bool
    let onToggle: () -> Void, onSettings: () -> Void, onHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(isActive ? Color.accentColor : Color.secondary.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(.body, design: .rounded)).bold()
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Run \(name) endpoint", isOn: Binding(get: { isActive }, set: { _ in onToggle() }))
                    .toggleStyle(.switch).labelsHidden().accessibilityLabel("Run \(name) endpoint")
                    .disabled(!isAvailable && !isActive)
            }
            if !isAvailable {
                Label("\(name) is not installed or signed in.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            } else if case .failed(let message) = status {
                Label(message, systemImage: "xmark.circle.fill").font(.caption2).foregroundStyle(.red)
            }
            HStack(spacing: 6) {
                StatusDot(status: status)
                Text(url).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                CopyButton(url); Spacer()
                Button("Help", action: onHelp).buttonStyle(.borderless)
                Button("Settings", action: onSettings).buttonStyle(.borderless)
            }.controlSize(.small)
        }.padding(11).background(Color.secondary.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
