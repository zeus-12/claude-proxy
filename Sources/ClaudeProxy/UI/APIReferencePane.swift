import SwiftUI

/// The "?" reference: one section per endpoint (Chat and Voice) describing
/// exactly what it exposes. Content comes from `APIDocs`, which is also what the
/// "Copy docs" buttons serialize — so what you read and what you paste always
/// match. Ports come from the live config so the URLs are accurate.
struct APIReferencePane: View {
    @EnvironmentObject var chat: ChatController
    @EnvironmentObject var voice: VoiceController

    private var sections: [APIDocs.Section] {
        [APIDocs.chat(baseURL: chat.config.baseURL),
         APIDocs.voice(endpointURL: voice.config.endpointURL)]
    }

    var body: some View {
        Form {
            ForEach(sections, id: \.title) { section in
                Section {
                    ForEach(section.entries, id: \.title) { entry in
                        FeatureRow(entry: entry)
                    }
                    CopyDocsButton(title: "Copy \(section.title) docs") {
                        APIDocs.markdown(for: section)
                    }
                } header: {
                    Label(section.title, systemImage: section.systemImage)
                }
            }

            Section {
                CopyDocsButton(title: "Copy all docs") {
                    APIDocs.markdown(for: sections)
                }
            } footer: {
                Text("Copies the full reference as Markdown, ready to paste into an LLM.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct FeatureRow: View {
    let entry: APIDocs.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.headline)
            Text(entry.detail).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(entry.code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                CopyButton(entry.code)
            }
        }
        .padding(.vertical, 3)
    }
}
