#if os(iOS)
import SwiftUI
import CpdbShared

/// State for SearchView's two filter groups: which entry kinds to
/// show, and which columns the text search consults. Defaults match
/// "show everything, search all columns" so first-run users see
/// nothing missing. Persisted to UserDefaults so the user's tweak
/// survives app relaunch.
struct SearchFilter: Equatable {
    /// Kinds to include in results. Default: all kinds present on
    /// the wire. Empty set means "show nothing" (we avoid that;
    /// FilterSheet clamps to at least one).
    var kinds: Set<EntryKind>
    /// Search the entry's title / text_preview.
    var scopeText: Bool
    /// Search extracted OCR text (image entries).
    var scopeOCR: Bool
    /// Search image classifier tags (image entries).
    var scopeTags: Bool

    static var `default`: SearchFilter {
        SearchFilter(
            kinds: Set(EntryKind.allCases),
            scopeText: true,
            scopeOCR: true,
            scopeTags: true
        )
    }

    /// True when this is the "show everything" configuration —
    /// drives the filter-button badge visibility in SearchView.
    var isDefault: Bool {
        self == .default
    }

    // MARK: - Persistence

    private static let udKey = "cpdb.ios.searchFilter"

    static func load() -> SearchFilter {
        let d = UserDefaults.standard
        guard let raw = d.dictionary(forKey: udKey) else { return .default }
        let kindStrings = (raw["kinds"] as? [String]) ?? []
        let kinds = Set(kindStrings.compactMap { EntryKind(rawValue: $0) })
        return SearchFilter(
            kinds: kinds.isEmpty ? Set(EntryKind.allCases) : kinds,
            scopeText: (raw["scopeText"] as? Bool) ?? true,
            scopeOCR:  (raw["scopeOCR"]  as? Bool) ?? true,
            scopeTags: (raw["scopeTags"] as? Bool) ?? true
        )
    }

    func save() {
        let raw: [String: Any] = [
            "kinds":     kinds.map { $0.rawValue },
            "scopeText": scopeText,
            "scopeOCR":  scopeOCR,
            "scopeTags": scopeTags,
        ]
        UserDefaults.standard.set(raw, forKey: Self.udKey)
    }

    // MARK: - SQL helpers

    /// Build a WHERE-clause fragment + bindings for the column-scope
    /// part of a search query. Only called when the user's search
    /// string is non-empty. Returns nil when all scopes are off
    /// (caller should treat as "match nothing"); our UI prevents
    /// that state.
    func scopeLikeClause(for searchString: String) -> (sql: String, args: [String])? {
        var fragments: [String] = []
        var args: [String] = []
        let like = "%\(searchString)%"
        if scopeText {
            fragments.append("title LIKE ?")
            fragments.append("text_preview LIKE ?")
            args.append(like); args.append(like)
        }
        if scopeOCR {
            fragments.append("ocr_text LIKE ?")
            args.append(like)
        }
        if scopeTags {
            fragments.append("image_tags LIKE ?")
            args.append(like)
        }
        guard !fragments.isEmpty else { return nil }
        return ("(\(fragments.joined(separator: " OR ")))", args)
    }
}

/// Modal sheet presented from SearchView's filter toolbar button.
/// Two sections: kind multiselect + search-column scopes. Writes
/// straight to the bound `SearchFilter`, which the caller persists
/// + reacts to via onChange.
struct FilterSheet: View {
    @Binding var filter: SearchFilter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(EntryKind.allCases, id: \.self) { kind in
                        Toggle(isOn: kindBinding(kind)) {
                            Label(Self.label(kind), systemImage: Self.icon(kind))
                        }
                    }
                } header: {
                    Text("Show these kinds")
                } footer: {
                    Text("Entries of unchecked kinds are hidden from the list.")
                }

                Section {
                    Toggle(isOn: $filter.scopeText) {
                        Label("Text & titles", systemImage: "text.alignleft")
                    }
                    Toggle(isOn: $filter.scopeOCR) {
                        Label("OCR (text in images)", systemImage: "text.viewfinder")
                    }
                    Toggle(isOn: $filter.scopeTags) {
                        Label("Image tags", systemImage: "tag")
                    }
                } header: {
                    Text("Search in")
                } footer: {
                    Text("Controls which columns your search query consults. At least one must stay on.")
                }

                Section {
                    Button("Reset to defaults") {
                        filter = .default
                    }
                    .disabled(filter.isDefault)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // If the user clicks every scope off, force the text scope
        // back on so queries always have something to match against.
        .onChange(of: filter.scopeText) { _, _ in enforceScopeFloor() }
        .onChange(of: filter.scopeOCR)  { _, _ in enforceScopeFloor() }
        .onChange(of: filter.scopeTags) { _, _ in enforceScopeFloor() }
        // Likewise clamp kinds — at least one must be selected.
        .onChange(of: filter.kinds) { old, new in
            if new.isEmpty {
                filter.kinds = old.isEmpty ? Set(EntryKind.allCases) : old
            }
        }
    }

    private func kindBinding(_ kind: EntryKind) -> Binding<Bool> {
        Binding(
            get: { filter.kinds.contains(kind) },
            set: { on in
                if on { filter.kinds.insert(kind) }
                else  { filter.kinds.remove(kind) }
            }
        )
    }

    private func enforceScopeFloor() {
        if !filter.scopeText && !filter.scopeOCR && !filter.scopeTags {
            filter.scopeText = true
        }
    }

    private static func label(_ kind: EntryKind) -> String {
        switch kind {
        case .text:  return "Text"
        case .link:  return "Links"
        case .image: return "Images"
        case .file:  return "Files"
        case .color: return "Colors"
        case .other: return "Other"
        }
    }

    private static func icon(_ kind: EntryKind) -> String {
        switch kind {
        case .text:  return "text.alignleft"
        case .link:  return "link"
        case .image: return "photo"
        case .file:  return "doc"
        case .color: return "paintpalette"
        case .other: return "questionmark.square"
        }
    }
}
#endif
