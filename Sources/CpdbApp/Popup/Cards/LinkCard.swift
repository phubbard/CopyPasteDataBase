import SwiftUI
import CpdbCore

/// Rendering for `link` entries.
///
/// Full URL is the primary signal — put it at the top in the primary text
/// colour so it's actually readable. Host + title, being derivative, go
/// below in the secondary/tertiary tint.
struct LinkCard: View {
    let row: EntryRepository.EntryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Full URL, top, fully dark, monospaced for readability.
            // No truncation — wrap it so long paths stay visible.
            Text(urlString)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                Text(hostString)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let title = row.entry.title, !title.isEmpty, title != urlString {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var urlString: String {
        row.entry.textPreview ?? row.entry.title ?? ""
    }

    private var hostString: String {
        guard let url = URL(string: urlString), let host = url.host else {
            return row.entry.title ?? urlString
        }
        return host
    }
}
