import AppKit
import SwiftUI

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case defaults
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .defaults: "Defaults"
        case .about: "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .defaults: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

// MARK: - Navigation state (singleton so the menu bar can jump to a tab)

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var selectedTab: SettingsTab? = .general
    private init() {}
}

// MARK: - Root view

struct SettingsView: View {
    @State private var navigation = SettingsNavigation.shared
    @State private var history: [SettingsTab] = [.general]
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var activeTab: SettingsTab { navigation.selectedTab ?? .general }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            SettingsSidebar(selectedTab: $navigation.selectedTab)
                .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsDetail(tab: activeTab)
        }
        .navigationTitle("Settings")
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 660, minHeight: 540)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex <= 0)
                Button { goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
            }
        }
        .onChange(of: navigation.selectedTab) { _, _ in record() }
    }

    private func goBack() {
        guard historyIndex > 0 else { return }
        isHistoryNavigation = true
        historyIndex -= 1
        navigation.selectedTab = history[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func goForward() {
        guard historyIndex < history.count - 1 else { return }
        isHistoryNavigation = true
        historyIndex += 1
        navigation.selectedTab = history[historyIndex]
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func record() {
        guard !isHistoryNavigation, let tab = navigation.selectedTab else { return }
        if history.last == tab { return }
        if historyIndex < history.count - 1 {
            history = Array(history.prefix(historyIndex + 1))
        }
        history.append(tab)
        historyIndex = history.count - 1
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab?

    var body: some View {
        List(selection: $selectedTab) {
            ForEach(SettingsTab.allCases) { tab in
                Label { Text(tab.title) } icon: { Image(systemName: tab.systemImage) }
                    .foregroundStyle(.primary)
                    .tag(tab)
            }

            Text(AppInfo.versionString)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .fontDesign(.monospaced)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
        }
        .listStyle(.sidebar)
        .scrollEdgeEffectStyleSoftIfAvailable()
        .navigationTitle("Settings")
    }
}

// MARK: - Detail routing

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettingsPane()
            case .defaults: DefaultsSettingsPane()
            case .about: AboutSettingsPane()
            }
        }
        .navigationTitle(tab.title)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - macOS 26 availability helper

extension View {
    /// macOS 26's `.scrollEdgeEffectStyle(.soft, …)` gives a progressive blur at
    /// the sidebar scroll edges. It only exists in the macOS 26 SDK; the current
    /// toolchain doesn't ship that SDK, so referencing the symbol won't compile
    /// even behind `#available`. This is a no-op until the build toolchain is
    /// updated, at which point the modifier can be restored here.
    func scrollEdgeEffectStyleSoftIfAvailable() -> some View { self }
}
