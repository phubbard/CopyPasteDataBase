# Windows handoff: sticky notes (Mac v3.4.0)

Implement Windows parity with the sticky-notes feature per the contract
in `docs/schema.md` § **Sticky notes (v15)** — that section is the spec;
the macOS implementation (shipped v3.4.0) is reference only. Update
`docs/parity.md` in your PR.

The short version, for orientation (the schema doc governs on conflict):

- `entries.note TEXT` (NULL = none). Whitespace-only normalizes to NULL
  on write; cap 4096 Unicode scalars (truncate local writes, store
  pulled notes as sent so a replica never re-pushes a truncated copy
  over a longer one).
- Notes are USER DATA: writing one bumps `modified_at` (LWW) and
  enqueues a push — the `pinned` precedent, NOT enrichment adopt-once.
- FTS gains a trailing `note` column. Make the rebuild LOSSLESS: copy
  the old index's `text` column forward rather than re-deriving it from
  the 2048-char `text_preview` (the Mac migration v15 does this; a
  preview-based rebuild silently truncates long-text search).
- Wire: Entry record `note` String. **Absent field = sender predates
  notes → preserve the local note even when the remote wins LWW.
  Empty string = deliberate clear.** A notes-aware sender always
  writes the field ("" for no note). Without this, a pin toggle from
  an old client silently wipes notes.
- Embedding: a note write deletes the entry's embedding row so the
  sweeper re-embeds with the note text folded in (notes are
  semantically searchable). On pull, adopt a record's embedding only
  if the note the row ends up with matches the note the record
  carries — otherwise you plant a vector that doesn't reflect the row.
- UI: note indicator on the card + edit affordance + a `.note`
  match-source badge; suppress FTS snippets for note-sourced hits in
  the card body (the note is not the clip's content).

Mac release gate that applies to you too: the CloudKit `note` field must
exist in the Production schema before any notes-aware build pushes
(every push writes the field). The Console deploy is a manual step —
container `iCloud.net.phfactor.cpdb` (mind the container picker).
