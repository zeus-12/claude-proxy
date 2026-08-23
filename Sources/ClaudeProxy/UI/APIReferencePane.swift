import SwiftUI

/// A provider-specific help page, so Claude and Codex instructions never mix.
struct APIReferencePane: View {
    let section: APIDocs.Section
    var body: some View {
        Form {
            Section {
                ForEach(section.entries, id: \.title) { FeatureRow(entry: $0) }
                CopyDocsButton(title: "Copy \(section.title) docs") { APIDocs.markdown(for: section) }
            } header: { Label(section.title, systemImage: section.systemImage) }
        }
        .formStyle(.grouped).scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
    }
}

private struct FeatureRow: View {
    let entry: APIDocs.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title).font(.headline)
            Text(entry.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(entry.code).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 5))
                CopyButton(entry.code)
            }
        }.padding(.vertical, 3)
    }
}
