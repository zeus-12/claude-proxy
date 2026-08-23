import SwiftUI

struct APIKeySection: View {
    @EnvironmentObject private var apiKey: APIKeyController
    let scope: APIKeyScope

    @State private var draft = ""
    @State private var revealed = false
    @State private var confirmingRegeneration = false

    var body: some View {
        Section("Access key") {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(isConfigured ? "Access key configured" : "Access key required")
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: isConfigured ? "checkmark.circle.fill" : "key.fill")
                        .foregroundStyle(isConfigured ? .green : .orange)
                }

                Text("Clients must send this local key with every request. It is not your \(scope.accountLabel) credential.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Group {
                        if revealed {
                            TextField("", text: $draft, prompt: Text("Paste or enter a key"))
                        } else {
                            SecureField("", text: $draft, prompt: Text("Paste or enter a key"))
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Access key")

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealed ? "Hide access key" : "Show access key")
                    .accessibilityLabel(revealed ? "Hide access key" : "Show access key")

                    CopyButton(draft)
                }
            }

            HStack(spacing: 8) {
                Button(isConfigured ? "Save changes" : "Save access key") {
                    save()
                }
                .disabled(!canSave)

                Button(isConfigured ? "Generate new key" : "Generate access key") {
                    if isConfigured {
                        confirmingRegeneration = true
                    } else {
                        generate()
                    }
                }
            }
            .controlSize(.small)

            if case .unavailable(let reason) = apiKey.state(scope) {
                Label(reason, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Stored locally with permissions limited to your macOS account. This access key never uses Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .confirmationDialog(
            "Generate a new \(scope.label) access key?",
            isPresented: $confirmingRegeneration
        ) {
            Button("Generate new key", role: .destructive) { generate() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Clients using the current key will stop working until you update them.")
        }
        .onAppear { draft = apiKey.key(scope) ?? "" }
    }

    private var isConfigured: Bool { apiKey.isConfigured(scope) }

    private var canSave: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (apiKey.key(scope) ?? "")
    }

    private var header: String {
        switch scope {
        case .claude, .codex: return "Authorization: Bearer <access-key>"
        case .voice: return "Authorization: Token <access-key>  ·  ?token=<access-key>"
        }
    }

    private func save() {
        if apiKey.save(draft, for: scope) {
            draft = apiKey.key(scope) ?? draft
        }
    }

    private func generate() {
        guard let key = apiKey.generate(scope) else { return }
        draft = key
        revealed = true
    }
}

private extension APIKeyScope {
    var accountLabel: String {
        switch self {
        case .claude, .voice: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
