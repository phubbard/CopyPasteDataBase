import SwiftUI
import CpdbCore
import CpdbShared

/// Rendering for `color` entries. Full-bleed swatch + hex label.
///
/// Two ways this renders:
/// 1. The entry is natively `.color` kind — we derive the hex from
///    `textPreview` or `title`.
/// 2. The entry is `.text` but the text *is* a hex color (e.g. `#FF3300`
///    copied from a color picker). `EntryCard` dispatches to `ColorCard`
///    with `hexOverride` set to the detected value.
struct ColorCard: View {
    let row: EntryRepository.EntryRow
    let hexOverride: String?

    init(row: EntryRepository.EntryRow, hexOverride: String? = nil) {
        self.row = row
        self.hexOverride = hexOverride
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(swatch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let hex = hexCode {
                Text(hex)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .padding(.bottom, 14)
            }
        }
    }

    /// Paste stores native color entries as `public.utf8-plain-text` with a
    /// `#RRGGBB` hex string, plus `com.apple.cocoa.pasteboard.color` with
    /// an NSKeyedArchived NSColor. We use the hex for display — parsing
    /// NSColor archives is future work.
    private var hexCode: String? {
        if let override = hexOverride { return override }
        let text = row.entry.textPreview ?? row.entry.title ?? ""
        return text.starts(with: "#") ? text : nil
    }

    private var swatch: Color {
        guard let hex = hexCode else { return .gray }
        return Color(hex: hex) ?? .gray
    }
}

private extension Color {
    /// Parse `#RRGGBB` or `#RRGGBBAA`.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s = String(s.dropFirst()) }
        guard let value = UInt64(s, radix: 16) else { return nil }
        let r, g, b, a: Double
        switch s.count {
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8)  & 0xFF) / 255
            b = Double( value        & 0xFF) / 255
            a = 1.0
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8)  & 0xFF) / 255
            a = Double( value        & 0xFF) / 255
        default:
            return nil
        }
        self.init(red: r, green: g, blue: b, opacity: a)
    }
}
