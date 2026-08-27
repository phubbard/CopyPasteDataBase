import SwiftUI
import CpdbShared

/// Compact action-chip row rendered at the bottom of a card's content
/// area from `entries.chips_json` — dates, addresses, phone numbers,
/// URLs, tracking/flight numbers, money amounts, and QR/barcode text
/// detected at capture or backfill time (`TextChipDetector`,
/// `QRChipMapper`).
///
/// A single HStack, not a wrapping FlowLayout: the card's fixed 320pt
/// width only ever has room for a few tight capsules, so a wrap layout
/// would add complexity for a state (mid-row wrap) that never actually
/// triggers — overflow past `maxVisible` collapses to a "+N" tag
/// instead, same idea as `EntryCard`'s existing badge capsules.
struct ChipRow: View {
    let chips: [Chip]

    private static let maxVisible = 3

    var body: some View {
        if !chips.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(chips.prefix(Self.maxVisible).enumerated()), id: \.offset) { _, chip in
                    chipButton(chip)
                }
                if chips.count > Self.maxVisible {
                    Text("+\(chips.count - Self.maxVisible)")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
            }
            // Deliberately no trailing Spacer: this row must hug its
            // own content width, not stretch to fill whatever frame a
            // caller wraps it in — `ImageCard` relies on that to align
            // it into a bottom-trailing overlay corner via `.frame(...,
            // alignment:)` on the *outside*, which only works if this
            // view doesn't already claim the full proposed width.
        }
    }

    // Deliberately not a `Button`: `EntryStripView` attaches
    // `.onTapGesture(count: 2)` (paste) / `.onTapGesture` (select) to
    // the whole card these chips render inside, and a `Button` claims
    // the hit-test region exclusively — a double-click landing on a
    // chip would fire the chip action twice (once per click of the
    // pair) and never reach the card's paste gesture at all. A plain
    // view + `.simultaneousGesture` lets this tap and the ancestor's
    // tap gestures both get a chance to recognize; `ChipAction.perform`
    // carries its own same-chip debounce (see its doc comment) to
    // collapse a double-click's two taps into one action.
    private func chipButton(_ chip: Chip) -> some View {
        HStack(spacing: 3) {
            Image(systemName: Self.symbol(for: chip.t))
                .font(.system(size: 9, weight: .semibold))
            Text(chip.s)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Self.color(for: chip.t)))
        .frame(maxWidth: 110)
        .help(chip.s)
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded { ChipAction.perform(chip) }
        )
    }

    private static func symbol(for type: String) -> String {
        switch type {
        case ChipType.date: return "calendar"
        case ChipType.address: return "mappin.and.ellipse"
        case ChipType.phone: return "phone.fill"
        case ChipType.url: return "link"
        case ChipType.tracking: return "shippingbox.fill"
        case ChipType.flight: return "airplane"
        case ChipType.money: return "dollarsign.circle.fill"
        default: return "qrcode"
        }
    }

    private static func color(for type: String) -> Color {
        switch type {
        case ChipType.date: return .orange
        case ChipType.address: return .green
        case ChipType.phone: return .blue
        case ChipType.url: return .accentColor
        case ChipType.tracking: return .purple
        case ChipType.flight: return .indigo
        case ChipType.money: return .teal
        default: return .secondary
        }
    }
}
