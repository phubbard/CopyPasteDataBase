import Foundation

/// A single detected "data chip" — a structured signal pulled out of an
/// entry's text or image content (a date, an address, a phone number, a
/// URL, a shipment tracking number, a flight number, a money amount, or
/// generic barcode text) that the popup card renders as a small tappable
/// action affordance. Serialized as a JSON array into `entries.chips_json`
/// (v12_semantic_enrichment schema — see `Schema.swift`).
///
/// `t` values in active use: `ChipType.date/.address/.phone/.url/
/// .tracking/.flight/.money` (detected from text via `TextChipDetector`)
/// plus `ChipType.text` (QR/barcode payloads that aren't a recognizable
/// URL or phone number — see `QRChipMapper`; kept for display/copy, not
/// a typed action).
public struct Chip: Codable, Equatable, Sendable {
    public var t: String
    /// The raw value an action operates on (a URL string, a phone
    /// number, an ISO 8601 date, a tracking number, ...).
    public var v: String
    /// Human-readable label for the chip's face. Falls back to `v` when
    /// there's nothing shorter/prettier to show.
    public var s: String

    public init(t: String, v: String, s: String) {
        self.t = t
        self.v = v
        self.s = s
    }
}

/// String constants for `Chip.t`, kept as an enum-of-statics (rather than
/// a Swift `enum` with a `rawValue`) so the wire format stays a plain
/// JSON string with no encoding indirection.
public enum ChipType {
    public static let date = "date"
    public static let address = "address"
    public static let phone = "phone"
    public static let url = "url"
    public static let tracking = "tracking"
    public static let flight = "flight"
    public static let money = "money"
    /// QR/barcode-only: a payload that isn't a recognizable URL or
    /// phone number. Not part of the original v12 chip-type set, but
    /// chips_json is an open JSON array — an unrecognized `t` is safe
    /// for any reader to skip, so this doesn't need a schema bump.
    public static let text = "text"
}

extension Chip {
    /// Decode `chips_json` into an array, treating nil / empty / corrupt
    /// JSON as "no chips" rather than throwing — a not-yet-scanned or
    /// malformed column value must never crash a card render.
    public static func decodeArray(_ json: String?) -> [Chip] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Chip].self, from: data)) ?? []
    }

    public static func encodeArray(_ chips: [Chip]) -> String {
        guard let data = try? JSONEncoder().encode(chips),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Merge freshly detected chips into whatever's already stored for
    /// an entry, de-duplicating on `(t, v)` so re-running detection (a
    /// QR pass landing after a text pass on the same captioned image, a
    /// backfill re-scan) never doubles up a chip already recorded.
    /// Existing chips keep their original order; new ones append in
    /// detection order. `existingJson: nil` (never scanned) and
    /// `existingJson: "[]"` (scanned, found nothing) both start from an
    /// empty array, same as `decodeArray`.
    public static func merge(existingJson: String?, adding newChips: [Chip]) -> String {
        var result = decodeArray(existingJson)
        var seen = Set(result.map { dedupeKey($0) })
        for chip in newChips {
            let key = dedupeKey(chip)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(chip)
        }
        return encodeArray(result)
    }

    private static func dedupeKey(_ chip: Chip) -> String {
        "\(chip.t)\u{0}\(chip.v)"
    }
}
