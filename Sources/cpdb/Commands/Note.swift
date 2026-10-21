#if os(macOS)
import ArgumentParser
import CpdbShared
import Foundation

/// `cpdb note` — read, set, or clear the user's sticky note on an entry.
///
///     cpdb note 42                     print the note
///     cpdb note 42 pay by Friday       set it (words joined with spaces)
///     cpdb note 42 --clear             remove it
///
/// Writes the same way the app does (`EntryRepository.setNote`: FTS row,
/// embedding invalidation, push-queue row) but never talks to CloudKit —
/// the CLI has no CloudKit entitlement; the running app drains the queue
/// and pushes.
///
/// A note longer than `EntryRepository.maxNoteLength` is rejected up
/// front rather than silently truncated.
///
/// The CLI is a separate process, so it can't invalidate a running app's
/// in-memory `EmbeddingIndex`: that buffer may keep serving the entry's
/// old vector until the app next invalidates it (any capture, a pulled
/// vector, or the embedding sweep — every 10–15 min — re-embedding the
/// entry from its new note). FTS and the stored note are correct
/// immediately; only the semantic ranking lags, and only briefly.
struct NoteCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "note",
        abstract: "Show, set, or clear the sticky note on an entry."
    )

    @Argument(help: "Entry id.")
    var id: Int64

    @Argument(help: "Note text. Omit to print the current note.")
    var text: [String] = []

    @Flag(name: .long, help: "Remove the note.")
    var clear: Bool = false

    func validate() throws {
        if clear && !text.isEmpty {
            throw ValidationError("--clear can't be combined with note text.")
        }
        let length = text.joined(separator: " ").unicodeScalars.count
        if length > EntryRepository.maxNoteLength {
            throw ValidationError(
                "note is \(length) characters; the limit is \(EntryRepository.maxNoteLength).")
        }
    }

    func run() throws {
        let store = try Store.open()
        let repo = EntryRepository(store: store)
        guard let entry = try repo.fetch(id: id), entry.deletedAt == nil else {
            Log.stderr("error: no entry with id \(id)")
            throw ExitCode.failure
        }

        if clear || !text.isEmpty {
            try repo.setNote(id: id, note: clear ? nil : text.joined(separator: " "))
            // Blank text clears too, so report what actually landed.
            let stored = try repo.note(id: id)
            Log.stderr(stored == nil ? "Cleared note on entry \(id)." : "Set note on entry \(id).")
            return
        }

        guard let note = entry.note else {
            Log.stderr("Entry \(id) has no note.")
            throw ExitCode.failure
        }
        print(note)
    }
}
#endif
