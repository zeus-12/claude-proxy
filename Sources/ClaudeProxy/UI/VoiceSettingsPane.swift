import SwiftUI
import AppKit

struct VoiceSettingsPane: View {
    @EnvironmentObject var voice: VoiceController
    @State private var portText = ""

    var body: some View {
        ScrollView {
            PanelCard {
                PanelRow("WebSocket URL", detail: voice.config.endpointURL) {
                    HStack(spacing: 8) {
                        CopyButton(voice.config.endpointURL)
                        StatusDot(status: voice.status)
                        Toggle(
                            "Run Voice endpoint",
                            isOn: Binding(get: { voice.isEnabled }, set: { _ in voice.toggle() })
                        )
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
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
                            .onChange(of: portText) { _, new in
                                let filtered = new.filter(\.isNumber)
                                if filtered != new { portText = filtered }
                            }
                        Button("Apply", action: applyPort)
                            .controlSize(.small)
                            .disabled(!portChanged || !portValid)
                    }
                }

                PanelDivider()
                APIKeyControls(scope: .voice)
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
        .onAppear { portText = String(voice.config.port) }
    }

    private var portValue: Int? { Int(portText) }
    private var portValid: Bool { (portValue.map { (1...65535).contains($0) }) ?? false }
    private var portChanged: Bool { portValue != voice.config.port }

    private func applyPort() {
        guard let p = portValue, portValid else { return }
        var c = voice.config
        c.port = p
        voice.apply(c)
    }
}
