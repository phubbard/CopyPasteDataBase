import AppKit
import Foundation
import CpdbShared

/// Tap-to-act behavior for a data chip (`ChipRow`). All actions are
/// best-effort and silently no-op on malformed data — a chip is a
/// convenience shortcut, never the only way to get at the underlying
/// value (it's still visible as plain text in the card body above it).
enum ChipAction {
    static func perform(_ chip: Chip) {
        switch chip.t {
        case ChipType.date:
            openCalendarEvent(chip)
        case ChipType.address:
            openMaps(chip.v)
        case ChipType.phone:
            let digits = chip.v.filter { $0.isNumber || $0 == "+" }
            openURL("tel:\(digits)")
        case ChipType.url:
            openURL(chip.v)
        case ChipType.tracking:
            NSWorkspace.shared.open(TrackingCarrier.trackingURL(for: chip.v))
        default:
            // money, flight, and the QR-only "text" type have no
            // natural "open" destination — copy the value instead so
            // the tap still does something useful.
            copyToPasteboard(chip.v)
        }
    }

    private static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openMaps(_ address: String) {
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? address
        guard let url = URL(string: "https://maps.apple.com/?address=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Generates a minimal one-event `.ics` file into the temp
    /// directory and opens it via the system's own calendar-import
    /// flow — avoids needing EventKit entitlements just for a tap
    /// action. `chip.v` is the ISO 8601 string `TextChipDetector`
    /// stores for date chips.
    private static func openCalendarEvent(_ chip: Chip) {
        guard let date = ISO8601DateFormatter().date(from: chip.v) else { return }
        let dtFormatter = DateFormatter()
        dtFormatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        dtFormatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = dtFormatter.string(from: date)
        // Naive 1-hour duration — the detector doesn't reliably surface
        // an end time, and a placeholder event the user can resize
        // beats no event at all.
        let end = dtFormatter.string(from: date.addingTimeInterval(3600))
        let summary = chip.s.isEmpty ? "Event" : chip.s
        let ics = """
            BEGIN:VCALENDAR
            VERSION:2.0
            PRODID:-//cpdb//chip-detector//EN
            BEGIN:VEVENT
            UID:\(UUID().uuidString)
            DTSTAMP:\(stamp)
            DTSTART:\(stamp)
            DTEND:\(end)
            SUMMARY:\(summary)
            END:VEVENT
            END:VCALENDAR
            """
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cpdb-chip-\(UUID().uuidString)")
            .appendingPathExtension("ics")
        do {
            try ics.write(to: fileURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(fileURL)
        } catch {
            Log.capture.error("chip: failed to write .ics temp file: \(String(describing: error), privacy: .public)")
        }
    }
}
