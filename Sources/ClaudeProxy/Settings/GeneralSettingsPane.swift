import SwiftUI

struct GeneralSettingsPane: View {
    /// Real CLI resolution result — never an assumed/optimistic status.
    @State private var resolved: ToolLocator.Resolved? = ToolLocator.resolve()

    var body: some View {
        Form {
            Section("Claude CLI") {
                LabeledContent("Status") {
                    if resolved != nil {
                        Label("Found", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Label("Not found", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .labelStyle(.titleAndIcon)
                    }
                }

                if let path = resolved?.claudePath {
                    LabeledContent("Path") {
                        Text(path)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("Install Claude Code and run `claude` once to log in, then re-check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Button("Re-check") {
                    resolved = ToolLocator.refresh()
                }
                .controlSize(.small)
            }

            Section {
                LabeledContent("Requests use your") {
                    Text("Claude Code subscription")
                }
            } footer: {
                Text("Each request runs the headless `claude` CLI with tools disabled. "
                     + "Responses come from your subscription, not the Anthropic API, and "
                     + "carry the agent's baseline context (~12k tokens per request).")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
