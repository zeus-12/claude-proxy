import SwiftUI
import AppKit

struct VoiceSettingsPane: View {
    @EnvironmentObject var voice: VoiceController
    @EnvironmentObject private var apiKey: APIKeyController
    @State private var portText = ""

    var body: some View {
        Form {
            APIKeySection(scope: .voice)

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
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Run endpoint")
                        Text("Accept local speech-to-text WebSocket connections.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!apiKey.isConfigured(.voice))

                if !apiKey.isConfigured(.voice) {
                    Label("Create an access key before starting this endpoint.", systemImage: "key.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                        Button("Apply port") { applyPort() }
                            .disabled(!portChanged || !portValid)
                    }
                }
                Toggle(isOn: Binding(
                    get: { voice.config.autoStart },
                    set: { voice.config.autoStart = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start at login")
                        Text("Run this endpoint whenever LLM Proxy launches.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!apiKey.isConfigured(.voice))
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
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
