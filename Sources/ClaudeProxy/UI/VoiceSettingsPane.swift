import SwiftUI
import AppKit

struct VoiceSettingsPane: View {
    @EnvironmentObject var voice: VoiceController
    @State private var portText = ""

    var body: some View {
        Form {
            Section("Endpoint") {
                LabeledContent("WebSocket URL") {
                    HStack(spacing: 6) {
                        Text(voice.config.endpointURL)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        CopyButton(voice.config.endpointURL)
                    }
                }
                LabeledContent("Status") {
                    EndpointStatusLabel(status: voice.status)
                }
                Toggle(isOn: Binding(get: { voice.isActive }, set: { _ in voice.toggle() })) {
                    Text(voice.isActive ? "Running" : "Stopped")
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
                    get: { voice.config.autoStart },
                    set: { voice.config.autoStart = $0 }
                ))
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
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
