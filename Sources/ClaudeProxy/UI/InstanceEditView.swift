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

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.model.trimmingCharacters(in: .whitespaces).isEmpty &&
        (1...65535).contains(draft.port)
    }
}
