import SwiftUI

struct ChatSettingsPane: View {
    @ObservedObject var chat: ChatController
    @EnvironmentObject private var apiKey: APIKeyController
    @State private var portText = ""

    var body: some View {
        Form {
            APIKeySection(scope: chat.backend.keyScope)

            Section("Endpoint") {
                LabeledContent("Base URL") {
                    HStack(spacing: 6) {
                        Text(chat.config.baseURL).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        CopyButton(chat.config.baseURL)
                    }
                }
                LabeledContent("Status") { EndpointStatusLabel(status: chat.status) }
                Toggle(isOn: Binding(get: { chat.isActive }, set: { _ in chat.toggle() })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run endpoint")
                        Text("Accept local requests at the base URL above.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!apiKey.isConfigured(chat.backend.keyScope)
                          || (!chat.isAvailable && !chat.isActive))

                if !apiKey.isConfigured(chat.backend.keyScope) {
                    Label("Create an access key before starting this endpoint.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Connection") {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", text: $portText).frame(width: 90).multilineTextAlignment(.trailing)
                            .accessibilityLabel("Port")
                            .onChange(of: portText) { _, value in
                                let filtered = value.filter(\.isNumber)
                                if filtered != value { portText = filtered }
                            }
                        Button("Apply port", action: applyPort)
                            .disabled(!portChanged || !portValid)
                    }
                }
                Toggle(isOn: Binding(
                    get: { chat.config.autoStart },
                    set: { chat.config.autoStart = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start at login")
                        Text("Run this endpoint whenever LLM Proxy launches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!apiKey.isConfigured(chat.backend.keyScope))
            }
            Section("\(chat.backend.title) models") {
                ForEach(chat.backend.models) { model in
                    LabeledContent(model.displayName) {
                        Text(model.rawValue).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
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
