import SwiftUI

struct ChatSettingsPane: View {
    @ObservedObject var chat: ChatController
    @State private var portText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PanelCard {
                    PanelRow("Base URL", detail: chat.config.baseURL) {
                        HStack(spacing: 8) {
                            CopyButton(chat.config.baseURL)
                            StatusDot(status: chat.status)
                            Toggle(
                                "Run \(chat.backend.title) endpoint",
                                isOn: Binding(get: { chat.isEnabled }, set: { _ in chat.toggle() })
                            )
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                            .disabled(!chat.isAvailable && !chat.isEnabled)
                        }
                    }

                    PanelDivider()

                    PanelRow("Port") {
                        HStack(spacing: 6) {
                            TextField("Port", text: $portText)
                                .textFieldStyle(.plain)
                                .font(.system(.callout, design: .monospaced))
                                .frame(width: 58)
                                .multilineTextAlignment(.trailing)
                                .compactFieldBackground()
                                .accessibilityLabel("Port")
                                .onChange(of: portText) { _, value in
                                    let filtered = value.filter(\.isNumber)
                                    if filtered != value { portText = filtered }
                                }
                            Button("Apply", action: applyPort)
                                .controlSize(.small)
                                .disabled(!portChanged || !portValid)
                        }
                    }

                    PanelDivider()
                    APIKeyControls(scope: chat.backend.keyScope)
                }

                VStack(alignment: .leading, spacing: 7) {
                    PanelSectionLabel(title: "Available models")
                        .padding(.leading, 4)

                    PanelCard {
                        ForEach(Array(chat.backend.models.enumerated()), id: \.element.id) { index, model in
                            PanelRow(model.displayName) {
                                Text(model.rawValue)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            if index < chat.backend.models.count - 1 {
                                PanelDivider()
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
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
