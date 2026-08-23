import SwiftUI

struct ChatSettingsPane: View {
    @ObservedObject var chat: ChatController
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Endpoint") {
                LabeledContent("Base URL") {
                    HStack(spacing: 6) {
                        Text(chat.config.baseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        CopyButton(chat.config.baseURL)
                    }
                }
                LabeledContent("Status") { EndpointStatusLabel(status: chat.status) }
                Toggle("Run endpoint", isOn: Binding(get: { chat.isActive }, set: { _ in chat.toggle() }))
                    .toggleStyle(.switch).disabled(!chat.isAvailable && !chat.isActive)
            }
            APIKeySection(scope: chat.backend.keyScope)
            Section("Configuration") {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", text: $portText).frame(width: 90).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Port")
                            .onChange(of: portText) { _, value in
                                let filtered = value.filter(\.isNumber)
                                if filtered != value { portText = filtered }
                            }
                        Button("Apply", action: applyPort).disabled(!portChanged || !portValid)
                    }
                }
                Toggle("Start automatically at launch", isOn: Binding(
                    get: { chat.config.autoStart }, set: { chat.config.autoStart = $0 }
                ))
            }
            Section("\(chat.backend.title) models") {
                ForEach(chat.backend.models) { model in
                    LabeledContent(model.displayName) {
                        Text(model.rawValue).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .onAppear { portText = String(chat.config.port) }
    }

    private var portValue: Int? { Int(portText) }
    private var portValid: Bool { portValue.map { (1...65535).contains($0) } ?? false }
    private var portChanged: Bool { portValue != chat.config.port }
    private func applyPort() {
        guard let port = portValue, portValid else { return }
        var config = chat.config; config.port = port; chat.apply(config)
    }
}
