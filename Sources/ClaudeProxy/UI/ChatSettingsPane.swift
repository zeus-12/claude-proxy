import SwiftUI
import AppKit

struct ChatSettingsPane: View {
    @EnvironmentObject var chat: ChatController
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Endpoint") {
                LabeledContent("Base URL") {
                    HStack(spacing: 6) {
                        Text(chat.config.baseURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(chat.config.baseURL)
                    }
                }
                LabeledContent("Status") {
                    EndpointStatusLabel(status: chat.status)
                }
                Toggle(isOn: Binding(get: { chat.isActive }, set: { _ in chat.toggle() })) {
                    Text(chat.isActive ? "Running" : "Stopped")
                }
                .toggleStyle(.switch)
            }

            Section {
                LabeledContent("Port") {
                    HStack(spacing: 8) {
                        TextField("Port", text: $portText)
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: portText) { _, new in
                                let f = new.filter(\.isNumber)
                                if f != new { portText = f }
                            }
                        Button("Apply") { applyPort() }
                            .disabled(!portChanged || !portValid)
                    }
                }
                Toggle("Start automatically at launch", isOn: Binding(
                    get: { chat.config.autoStart },
                    set: { chat.config.autoStart = $0 }
                ))
            } header: {
                Text("Configuration")
            }

            Section("Allowed models") {
                ForEach(ChatModel.allCases) { model in
                    LabeledContent(model.displayName) {
                        Text(model.rawValue).font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .onAppear { portText = String(chat.config.port) }
    }

    private var portValue: Int? { Int(portText) }
    private var portValid: Bool { (portValue.map { (1...65535).contains($0) }) ?? false }
    private var portChanged: Bool { portValue != chat.config.port }

    private func applyPort() {
        guard let p = portValue, portValid else { return }
        var c = chat.config
        c.port = p
        chat.apply(c)
    }
}
