import SwiftUI

/// A provider-specific help page, so Claude and Codex instructions never mix.
struct APIReferencePane: View {
    let section: APIDocs.Section

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    PanelSectionLabel(title: "Quick reference")
                    Spacer()
                    CopyDocsButton(title: "Copy") {
                        APIDocs.markdown(for: section)
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)

                ForEach(section.entries, id: \.title) { entry in
                    FeatureRow(entry: entry)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.hidden)
    }
}

private struct FeatureRow: View {
    let entry: APIDocs.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title)
                .font(.callout.weight(.semibold))
            Text(entry.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(entry.code)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                CopyButton(entry.code)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            .background(
                Color.black.opacity(0.2),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .padding(12)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075))
        }
    }
}
