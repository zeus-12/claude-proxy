import SwiftUI

struct AboutSettingsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Name") { Text(AppInfo.name) }
                LabeledContent("Version") { Text("\(AppInfo.version) (\(AppInfo.build))") }
            }

            Section("What it does") {
                Text("Claude Proxy exposes a local OpenAI-compatible endpoint "
                     + "(`/v1/chat/completions`) for each instance, backed by the headless "
                     + "`claude` CLI. Point any OpenAI-style client at the instance's base URL.")
                    .font(.callout)
            }

            Section {
                Text("This routes a Claude Code subscription through a general-purpose API "
                     + "endpoint. That is in tension with Anthropic's terms, which license the "
                     + "subscription for use through their client — not as a redistributable "
                     + "gateway. Output also carries the agent's baseline context. Use at your "
                     + "own risk.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Heads up", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
