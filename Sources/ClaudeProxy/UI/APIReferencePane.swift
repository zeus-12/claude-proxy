import SwiftUI

/// A provider-specific help page, so Claude and Codex instructions never mix.
struct APIReferencePane: View {
    let section: APIDocs.Section
    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: section.systemImage)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.title2.bold())
                        Text("Endpoints, request formats, supported features, and examples.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                    CopyDocsButton(title: "Copy API reference") {
                        APIDocs.markdown(for: section)
                    }
                }
            }

            Section("Reference") {
                ForEach(section.entries, id: \.title) { FeatureRow(entry: $0) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}

private struct FeatureRow: View {
    let entry: APIDocs.Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(entry.title).font(.body.weight(.semibold))
            Text(entry.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(entry.code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                CopyButton(entry.code)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }
}
