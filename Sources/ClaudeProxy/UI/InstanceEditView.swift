import SwiftUI

struct InstanceEditView: View {
    @State private var draft: ProxyInstance
    @State private var portText: String
    let onSave: (ProxyInstance) -> Void
    let onCancel: () -> Void

    init(instance: ProxyInstance,
         onSave: @escaping (ProxyInstance) -> Void,
         onCancel: @escaping () -> Void) {
        _draft = State(initialValue: instance)
        _portText = State(initialValue: String(instance.port))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Instance").font(.headline)

            Form {
                TextField("Name", text: $draft.name)

                Picker("Model", selection: $draft.model) {
                    ForEach(suggestedModels, id: \.self) { Text($0).tag($0) }
                    if !suggestedModels.contains(draft.model) {
                        Text(draft.model).tag(draft.model)
                    }
                }

                TextField("Custom model id", text: $draft.model)
                    .font(.system(.body, design: .monospaced))

                TextField("Port", text: $portText)
                    .onChange(of: portText) { _, newValue in
                        let filtered = newValue.filter(\.isNumber)
                        if filtered != newValue { portText = filtered }
                        if let port = Int(filtered) { draft.port = port }
                    }

                Toggle("Start automatically at launch", isOn: $draft.autoStart)
            }

            endpoints

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    /// Shows the OpenAI-compatible endpoints this instance serves and which one
    /// supports streaming. Streaming is the standard OpenAI mechanism — set
    /// `"stream": true` on a chat request and the server replies with an SSE
    /// `text/event-stream` of `chat.completion.chunk` deltas.
    private var endpoints: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Endpoints").font(.caption).foregroundStyle(.secondary)
            endpointRow("POST", "/v1/chat/completions", streaming: true)
            endpointRow("GET", "/v1/models", streaming: false)
            Text("Streaming: send `\"stream\": true` to receive SSE deltas.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func endpointRow(_ method: String, _ path: String, streaming: Bool) -> some View {
        HStack(spacing: 6) {
            Text(method)
                .font(.system(.caption2, design: .monospaced)).bold()
                .frame(width: 36, alignment: .leading)
            Text(path).font(.system(.caption2, design: .monospaced))
            if streaming {
                Label("stream", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }
            Spacer()
        }
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.model.trimmingCharacters(in: .whitespaces).isEmpty &&
        (1...65535).contains(draft.port)
    }
}
