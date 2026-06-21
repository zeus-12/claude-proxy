import SwiftUI

/// Defaults applied when you add a new instance from the menu bar. Existing
/// instances are unaffected.
struct DefaultsSettingsPane: View {
    @AppStorage(DefaultsKey.defaultModel) private var defaultModel = "sonnet"
    @AppStorage(DefaultsKey.basePort) private var basePort = 8787
    @State private var basePortText = ""

    var body: some View {
        Form {
            Section {
                Picker("Model", selection: $defaultModel) {
                    ForEach(suggestedModels, id: \.self) { Text($0).tag($0) }
                    if !suggestedModels.contains(defaultModel) {
                        Text(defaultModel).tag(defaultModel)
                    }
                }
                .pickerStyle(.menu)
            } header: {
                Text("New instances")
            } footer: {
                Text("The Claude model assigned to each new instance you create.")
            }

            Section {
                LabeledContent("Starting port") {
                    TextField("8787", text: $basePortText)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                        .onChange(of: basePortText) { _, new in
                            let filtered = new.filter(\.isNumber)
                            if filtered != new { basePortText = filtered }
                            if let port = Int(filtered), (1...65535).contains(port) {
                                basePort = port
                            }
                        }
                }
            } footer: {
                Text("New instances are assigned the first free port at or above this number.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
        .onAppear { basePortText = String(basePort) }
    }
}
