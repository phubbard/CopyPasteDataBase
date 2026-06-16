import Foundation

/// In-memory, session-scoped undo/redo for reversible entry mutations
/// (delete, pin/unpin). One instance per device; the Mac app and the iOS
/// app each own one and wire their own affordance (⌘Z / snackbar / shake)
/// to the same logic here.
///
/// It is the ENTRY POINT for undoable mutations: call `delete` / `setPinned`
/// instead of the repository methods directly, and the inverse is recorded
/// automatically. Because every delete/pin already funnels through
/// `EntryRepository`, routing the user-initiated ones through here gives
/// undo to every UI path (popup, context menu, swipe) for free.
///
/// Cross-device correctness is handled one layer down: every mutation bumps
/// `modified_at`, and the pull path resolves deletes/pins by last-writer-
/// wins, so an undone delete propagates instead of staying deleted on a
/// sibling (see `EntryRepository` + `CloudKitSyncer.upsert`).
///
/// Not thread-safe by design — drive it from a single (UI) thread. The
/// repository writes it performs are single-row and synchronous.
public final class UndoCoordinator {

    /// What a performed/undone/redone action was, for the UI to phrase a
    /// toast or status hint.
    public struct ActionDescription: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case delete, pin, unpin, restore }
        public let kind: Kind
        public let entryId: Int64

        /// Verb-noun for composing "Undo \(label)" / "Redo \(label)".
        public var label: String {
            switch kind {
            case .delete:  return "Delete"
            case .restore: return "Restore"
            case .pin:     return "Pin"
            case .unpin:   return "Unpin"
            }
        }
        /// Past tense for a just-happened toast ("Deleted", "Pinned").
        public var pastTense: String {
            switch kind {
            case .delete:  return "Deleted"
            case .restore: return "Restored"
            case .pin:     return "Pinned"
            case .unpin:   return "Unpinned"
            }
        }
    }

    /// The reversible record kept on the stacks. Stores the inverse inline.
    private enum Action {
        case delete(entryId: Int64)
        case pin(entryId: Int64, from: Bool, to: Bool)

        /// How this action reads when it's the next thing to UNDO.
        var asPerformed: ActionDescription {
            switch self {
            case .delete(let id):
                return .init(kind: .delete, entryId: id)
            case .pin(let id, _, let to):
                return .init(kind: to ? .pin : .unpin, entryId: id)
            }
        }
    }

    private let repo: EntryRepository
    private var undoStack: [Action] = []
    private var redoStack: [Action] = []
    public let maxDepth: Int

    public init(repo: EntryRepository, maxDepth: Int = 50) {
        self.repo = repo
        self.maxDepth = maxDepth
    }

    // MARK: - Undoable mutations (perform + record)

    /// Delete (tombstone) an entry and record the inverse. Returns the
    /// description for a toast/hint.
    @discardableResult
    public func delete(id: Int64) throws -> ActionDescription {
        try repo.tombstone(id: id)
        push(.delete(entryId: id))
        return .init(kind: .delete, entryId: id)
    }

    /// Set an entry's pin state and record the inverse. Returns nil when
    /// it was a no-op (already in that state, or the entry isn't live).
    @discardableResult
    public func setPinned(id: Int64, pinned: Bool) throws -> ActionDescription? {
        guard let current = try repo.pinnedState(id: id), current != pinned else { return nil }
        try repo.setPinned(id: id, pinned: pinned)
        push(.pin(entryId: id, from: current, to: pinned))
        return .init(kind: pinned ? .pin : .unpin, entryId: id)
    }

    // MARK: - Undo / redo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    /// Label for the next undo, e.g. "Undo Delete" — nil when nothing to undo.
    public var undoMenuTitle: String? {
        undoStack.last.map { "Undo \($0.asPerformed.label)" }
    }
    public var redoMenuTitle: String? {
        redoStack.last.map { "Redo \($0.asPerformed.label)" }
    }

    /// Reverse the most recent action. Returns a description of what the
    /// undo PRODUCED (e.g. undoing a delete → `.restore`) so the UI can
    /// confirm it ("Restored"), or nil if the stack was empty.
    @discardableResult
    public func undo() throws -> ActionDescription? {
        guard let action = undoStack.popLast() else { return nil }
        let result: ActionDescription
        switch action {
        case .delete(let id):
            try repo.restore(id: id)
            result = .init(kind: .restore, entryId: id)
        case .pin(let id, let from, _):
            try repo.setPinned(id: id, pinned: from)
            result = .init(kind: from ? .pin : .unpin, entryId: id)
        }
        redoStack.append(action)
        return result
    }

    /// Re-apply the most recently undone action.
    @discardableResult
    public func redo() throws -> ActionDescription? {
        guard let action = redoStack.popLast() else { return nil }
        let result: ActionDescription
        switch action {
        case .delete(let id):
            try repo.tombstone(id: id)
            result = .init(kind: .delete, entryId: id)
        case .pin(let id, _, let to):
            try repo.setPinned(id: id, pinned: to)
            result = .init(kind: to ? .pin : .unpin, entryId: id)
        }
        undoStack.append(action)
        return result
    }

    /// Drop all history (e.g. on a destructive bulk operation that would
    /// make stale undos dangerous).
    public func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    // MARK: - Internals

    private func push(_ action: Action) {
        undoStack.append(action)
        // A fresh action invalidates the redo timeline.
        redoStack.removeAll()
        // Bound the stack — drop the oldest when over depth.
        if undoStack.count > maxDepth {
            undoStack.removeFirst(undoStack.count - maxDepth)
        }
    }
}
