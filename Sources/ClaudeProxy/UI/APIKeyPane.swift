import SwiftUI

struct APIKeyControls: View {
    @EnvironmentObject private var apiKey: APIKeyController
    let scope: APIKeyScope

    @State private var draft = ""
    @State private var revealed = false

    var body: some View {
        PanelRow("Require API key", detail: environmentManaged ? "Set by the environment" : nil) {
            Toggle("Require API key", isOn: Binding(
                get: { apiKey.isRequired(scope) },
                set: setRequired
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(environmentManaged)
            .help(environmentManaged
                  ? "\(APIKey.environmentName(for: scope)) is set, so this endpoint always requires a key."
                  : "Require clients to send an API key.")
        }
        .onAppear { draft = apiKey.key(scope) ?? "" }

        if environmentManaged {
            PanelDivider()

            // The environment key is what the server enforces, so editing the
            // stored one here would change nothing a client can observe.
            PanelRow("API key", detail: "Read from the environment") {
                Text(APIKey.environmentName(for: scope))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } else if apiKey.isRequired(scope) {
            PanelDivider()

            PanelRow("API key") {
                HStack(spacing: 6) {
                    Group {
                        if revealed {
                            TextField("API key", text: $draft)
                        } else {
                            SecureField("API key", text: $draft)
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.plain)
                    .frame(width: 132)
                    .compactFieldBackground()
                    .onSubmit(save)

                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(revealed ? "Hide API key" : "Show API key")

                    Button("Apply", action: save)
                        .controlSize(.small)
                        .disabled(!canSave)

                    Button(action: generate) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Generate new API key")
                    .accessibilityLabel("Generate new API key")
                }
            }
        }

        if case .unavailable(let reason) = apiKey.state(scope) {
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(12)
        }
    }

    private var environmentManaged: Bool { apiKey.isEnvironmentManaged(scope) }

    private var canSave: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != (apiKey.key(scope) ?? "")
    }

    private func setRequired(_ required: Bool) {
        if required, !apiKey.isConfigured(scope) {
            guard let key = apiKey.generate(scope) else { return }
            draft = key
            revealed = true
        }
        apiKey.setRequired(required, for: scope)
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
