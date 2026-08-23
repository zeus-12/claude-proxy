import SwiftUI

struct APIKeySection: View {
    @EnvironmentObject var apiKey: APIKeyController
    let scope: APIKeyScope

    @State private var draft = ""
    @State private var revealed = false
    @State private var confirmingDisable = false

    var body: some View {
        Section("API key") {
            Toggle(isOn: enabledBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Require an API key")
                    Text("Protects this local endpoint. Your \(scope.label) subscription sign-in is separate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if apiKey.isEnabled(scope) {
                LabeledContent("Key") {
                    HStack(spacing: 6) {
                        Group {
                            if revealed {
                                TextField("", text: $draft)
                            } else {
                                SecureField("", text: $draft)
                            }
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)

                        Button { revealed.toggle() } label: {
                            Image(systemName: revealed ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                        .help(revealed ? "Hide" : "Show")
                        .accessibilityLabel(revealed ? "Hide API key" : "Show API key")

                        CopyButton(draft)
                    }
                }

                HStack(spacing: 8) {
                    Button("Apply") { apiKey.save(draft, for: scope) }
                        .disabled(!changed || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Regenerate") {
                        apiKey.regenerate(scope)
                        draft = apiKey.key(scope) ?? ""
                    }
                }
                .controlSize(.small)
            }

            status
        }
        .confirmationDialog("Turn authentication off for \(scope.label)?",
                            isPresented: $confirmingDisable) {
            Button("Turn off authentication", role: .destructive) {
                apiKey.disable(scope)
                draft = ""
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Apps and websites on this Mac will be able to use your \(scope.subscriptionName) through this endpoint without a key.")
        }
        .onAppear {
            if apiKey.isEnabled(scope) { draft = apiKey.key(scope) ?? "" }
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { apiKey.isEnabled(scope) },
            set: { enabled in
                if enabled {
                    apiKey.setEnabled(true, for: scope)
                    draft = apiKey.key(scope) ?? ""
                } else {
                    confirmingDisable = true
                }
            }
        )
    }

    @ViewBuilder
    private var status: some View {
        switch apiKey.state(scope) {
        case .required:
            Text(header)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .disabled:
            Text("Off — requests to this endpoint do not need an API key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unavailable(let reason):
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var header: String {
        switch scope {
        case .claude, .codex: return "Send as:  Authorization: Bearer <key>"
        case .voice: return "Send as:  Authorization: Token <key>  ·  ?token=<key>"
        }
    }

    private var changed: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != (apiKey.key(scope) ?? "")
    }
}

private extension APIKeyScope {
    var subscriptionName: String {
        switch self {
        case .claude, .voice: return "Claude Code subscription"
        case .codex: return "Codex subscription"
        }
    }
}
