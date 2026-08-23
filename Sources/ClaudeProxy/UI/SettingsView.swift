import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case claude
    case codex
    case voice
    case claudeHelp
    case codexHelp
    case voiceHelp
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .voice: return "Voice"
        case .claudeHelp: return "Claude API"
        case .codexHelp: return "Codex API"
        case .voiceHelp: return "Voice API"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .claude: return "sparkles"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .voice: return "waveform"
        case .claudeHelp, .codexHelp, .voiceHelp: return "book.closed"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var claude: ChatController
    @ObservedObject var codex: ChatController
    @ObservedObject var voice: VoiceController
    @ObservedObject var apiKey: APIKeyController

    @State private var history: [SettingsTab] = [.claude]
    @State private var historyIndex = 0
    @State private var followingHistory = false

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 230)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(navigation.selectedTab.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 520)
        .environmentObject(apiKey)
        .environmentObject(voice)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                }
                .disabled(historyIndex == 0)
                .help("Back")

                Button(action: goForward) {
                    Image(systemName: "chevron.right")
                }
                .disabled(historyIndex >= history.count - 1)
                .help("Forward")
            }
        }
        .onChange(of: navigation.selectedTab) { _, tab in record(tab) }
    }

    private var sidebar: some View {
        List(selection: $navigation.selectedTab) {
            Section("Endpoints") {
                tabRow(.claude)
                tabRow(.codex)
                tabRow(.voice)
            }

            Section("Help") {
                tabRow(.claudeHelp)
                tabRow(.codexHelp)
                tabRow(.voiceHelp)
            }

            Section {
                tabRow(.about)
            }

            Text(versionText)
                .font(.footnote.monospaced())
                .foregroundStyle(.tertiary)
                .listRowSeparator(.hidden)
        }
        .listStyle(.sidebar)
        .navigationTitle("Settings")
    }

    private func tabRow(_ tab: SettingsTab) -> some View {
        Label(tab.title, systemImage: tab.systemImage).tag(tab)
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selectedTab {
        case .claude:
            ChatSettingsPane(chat: claude)
        case .codex:
            ChatSettingsPane(chat: codex)
        case .voice:
            VoiceSettingsPane()
        case .claudeHelp:
            APIReferencePane(section: APIDocs.chat(backend: .claude, baseURL: claude.config.baseURL))
        case .codexHelp:
            APIReferencePane(section: APIDocs.chat(backend: .codex, baseURL: codex.config.baseURL))
        case .voiceHelp:
            APIReferencePane(section: APIDocs.voice(endpointURL: voice.config.endpointURL))
        case .about:
            AboutPane()
        }
    }

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "Version \(version)"
    }

    private func record(_ tab: SettingsTab) {
        guard !followingHistory else { return }
        guard history[safe: historyIndex] != tab else { return }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(tab)
        historyIndex = history.count - 1
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        followingHistory = true
        historyIndex -= 1
        navigation.selectedTab = history[historyIndex]
        Task { @MainActor in followingHistory = false }
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        followingHistory = true
        historyIndex += 1
        navigation.selectedTab = history[historyIndex]
        Task { @MainActor in followingHistory = false }
    }
}

private struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 72, height: 72)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("LLM Proxy").font(.largeTitle.bold())
                        Text("One subscription. AI in every app.")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("Local, access-key-protected endpoints for Claude, Codex, and voice.")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Privacy") {
                Text("Endpoints bind only to 127.0.0.1. Access keys stay in your private Application Support folder, and LLM Proxy never stores provider passwords.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
