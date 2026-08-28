import AppKit
import Foundation
import CpdbShared

/// Tap-to-act behavior for a data chip (`ChipRow`). All actions are
/// best-effort and silently no-op on malformed data — a chip is a
/// convenience shortcut, never the only way to get at the underlying
/// value (it's still visible as plain text in the card body above it).
enum ChipAction {
    /// Pending, not-yet-fired taps keyed by `"\(chip.t)|\(chip.v)"`,
    /// scheduled by `tap(_:)` below.
    private static var pendingTaps: [String: DispatchWorkItem] = [:]

    /// Entry point for `ChipRow`'s tap gesture — NOT `perform(_:)`
    /// directly. `ChipRow` can't use a `Button` for these (see its doc
    /// comment) without swallowing the card's own double-click-to-
    /// paste gesture, and without `Button`'s single-hit-test
    /// exclusivity a double-click's two individual clicks each
    /// independently recognize as a tap on this same chip — landing
    /// alongside the ancestor card's `.onTapGesture(count: 2)` paste,
    /// not instead of it. A same-chip double-click is therefore never
    /// "the user tapped this chip twice"; it's "the user double-
    /// clicked the card to paste it, and it happened to land on a
    /// chip" — the chip action must NOT fire at all in that case (an
    /// unexpected browser tab / `.ics` import alongside a paste the
    /// user only meant as a paste), not just fire once instead of
    /// twice.
    ///
    /// So a single tap doesn't act immediately: it schedules `perform`
    /// after `NSEvent.doubleClickInterval` — the same window AppKit
    /// itself uses to decide two clicks are "one double-click" rather
    /// than two separate single-clicks. If a second tap on the SAME
    /// chip arrives before that timer fires, it's part of a double-
    /// click: cancel the pending action instead of performing (or
    /// re-scheduling) it, and let the ancestor's paste gesture own the
    /// click. A genuine single tap still acts, just after a brief,
    /// user-imperceptible delay.
    static func tap(_ chip: Chip) {
        let key = "\(chip.t)|\(chip.v)"
        if let pending = pendingTaps[key] {
            pending.cancel()
            pendingTaps[key] = nil
            return
        }
        let work = DispatchWorkItem {
            pendingTaps[key] = nil
            perform(chip)
        }
        pendingTaps[key] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

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

    /// Schemes a click hands straight to `NSWorkspace` with no
    /// confirmation: opening a web page or composing an email is the
    /// same "follow a link" action a user already takes for granted
    /// everywhere else in the OS. Every other scheme — including QR-only
    /// ones like `shortcuts:`, `file:`, or a Settings-pane URL — gets a
    /// confirmation dialog naming the exact destination before
    /// `NSWorkspace.open` runs, since a QR code is attacker-controlled
    /// content decoded off an arbitrary pasted/screenshotted image, not
    /// something the user typed or reviewed like a normal browser
    /// address bar entry.
    private static let noConfirmationSchemes: Set<String> = ["http", "https", "mailto", "tel"]

    private static func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        let scheme = (url.scheme ?? "").lowercased()
        guard noConfirmationSchemes.contains(scheme) else {
            confirmAndOpen(url)
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Shows the full destination and asks before handing an
    /// unrecognized-scheme URL to `NSWorkspace.open` — see
    /// `noConfirmationSchemes`.
    private static func confirmAndOpen(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Open This Link?"
        alert.informativeText = "This chip wants to open:\n\(url.absoluteString)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openMaps(_ address: String) {
        var allowed = CharacterSet.urlQueryAllowed
        // `.urlQueryAllowed` treats '&', '+', and '=' as legal query
        // characters (they're query-string *syntax*, not something
        // that needs escaping per RFC 3986) — fine for a single
        // fully-controlled key/value pair, but an address value can
        // contain any of the three ("Fifth & Main St", "5+5 Elm St")
        // and each one is misread by Maps' query parser: '&' truncates
        // the address at that point (starts a new bogus parameter),
        // and '+' decodes back to a literal space instead of surviving
        // as punctuation. Excluding them here forces them to be
        // percent-encoded so the address arrives intact.
        allowed.remove(charactersIn: "&+=")
        let encoded = address.addingPercentEncoding(withAllowedCharacters: allowed) ?? address
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
        // Fixed-format (non-user-facing) date strings need a fixed
        // locale, per Apple's guidance — without it, `DateFormatter`
        // defaults to `Locale.current`, and on a system whose calendar
        // preference is Buddhist (a real, if uncommon, macOS Region
        // setting) this silently emits a Buddhist-era year (e.g. 2569
        // instead of 2026) into the .ics file instead of a Gregorian
        // one, landing the imported event centuries off.
        dtFormatter.locale = Locale(identifier: "en_US_POSIX")
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
