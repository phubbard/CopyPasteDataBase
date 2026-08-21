# Hand-off: popup summon latency — instrument + tune (Windows port)

> **Origin:** macOS, commit `38be058`, shipping in **cpdb 3.2.2**
> (2026-08-20). The Mac popup summon measured **867.7ms** on an M2 —
> for a window that should feel instant — and came down to **113ms
> cold / 36ms warm** with four targeted fixes. cpdb-win's popup very
> likely harbors the same failure classes; this doc briefs the Windows
> session to run the same play. This is a *method* handoff, not a
> line-by-line port: measure your own path first, then fix what the
> numbers indict — the Mac ranking was NOT what intuition predicted.

## TL;DR — the method

1. **Instrument before touching anything, and keep the instrumentation
   forever.** On the Mac: a permanent info-level `popup-perf` log line
   emitted once per summon with per-stage timings (show-entry →
   data-refresh → window-position → activate → first-frame) plus
   per-item load counters (`thumbLoads`, `thumbMs`, and a counter for
   the specific suspected sin — on Mac, per-card DB opens). One line,
   near-zero cost, and future regressions get caught by a log filter
   instead of a hunch. Mirror it: same stages, same one-line format,
   logged via the existing Windows logging path.
2. Fix ranked by measurement. The Mac profile (rows=200, 10k-entry
   library) and what each number turned out to be:

| Stage | ms | Root cause |
|---|---|---|
| reposition | **319.7** | `setFrame(display: true)` force-drawing the **hidden** window's eagerly-built 200-card view tree |
| live-updates | **253.2** | five aggregate status queries (COUNT/MAX/SUM) running synchronously *before* the window shows |
| firstFrame | 173.8 | non-lazy strip: all 200 cards built, not the ~12 visible |
| makeKey | 87.1 | window activation (mostly irreducible) |
| refresh | 33.7 | the actual 200-row fetch — nearly innocent |
| (spread) | 103.5 | **142 fresh DB connection opens** — one per image/link card, per render |

3. Re-measure with identical methodology; put before/after numbers in
   `windows/CHANGELOG.md`. The Mac acceptance evidence was the perf
   line itself: `storeOpens` 142 → 0, thumb loads 142-sync → 6-async,
   total 868 → 113/36.

## The four fix classes, with Windows analogues

**1. Lazy item realization.** Mac: SwiftUI `HStack` → `LazyHStack`
(one word; cards already had fixed 320×360 frames, which lazy layouts
need for stable scrolling). Windows: check whether the popup strip
actually virtualizes. A `ListView` virtualizes by default **unless**
its `ItemsPanel` was swapped to a plain horizontal `StackPanel` (the
common way horizontal strips get built — and exactly how
virtualization silently dies). `ItemsStackPanel`/
`VirtualizingStackPanel` with fixed item extents, or `ItemsRepeater`
with a virtualizing layout. Verify empirically: instrument item-
container creation count on first show — it should be ~viewport-sized,
not row-count-sized.

**2. No forced layout/draw of a hidden window.** Mac: the pre-show
reposition passed `display: true`, forcing a synchronous render of an
invisible window. Windows: look for anything on the summon path that
forces `Measure`/`Arrange`/`UpdateLayout` — or waits on render — before
`Activate()`/`Show()`. Position the window without forcing layout; let
the normal presentation pass draw it once, visible.

**3. Defer status/aggregate work past first paint.** Mac: a
change-observation ran five aggregate queries (`COUNT`, `MAX`, `SUM`
over 4k rows) synchronously pre-show, though nothing consumed the
result before first frame; moved to one runloop-turn after first
paint. Windows: any "total items" counts, watermark queries, or
change-watcher bootstrapping that runs on the summon path — defer it
(`DispatcherQueue.TryEnqueue` after first frame, or lazy-start on
first change). Watch the ordering trap the Mac review caught: if the
deferred work and the item thumbnails share one serialized DB
connection, enqueue the *thumbnails first* or the deferred aggregates
will still blank every thumbnail for their full duration.

**4. One shared connection + async thumbnails.** Mac's cards each
called `Store.open()` — a fresh connection + migrator check — per
card, per render, on the UI thread. Windows: grep item templates,
value converters, and code-behind for `new SqliteConnection` (or any
repository construction) inside per-item paths; route everything
through the app's existing shared repository. Load thumbnails
asynchronously with the current placeholder while loading, and make
sure bitmap decode happens off the UI thread and doesn't re-fire on
every container recycle (cache by entry id; re-key only when a
late-arriving thumbnail write actually lands — the Mac uses a
refresh-token keyed to live updates so backfilled link thumbnails
still appear without re-querying on unrelated refreshes).

## Pitfalls the Mac review caught (check for their twins)

- Lazy + async keyed only on item id silently **breaks late-arriving
  thumbnails** (link/oEmbed images written after first render) — the
  old eager re-query-on-every-render behavior was accidentally
  load-bearing. Re-key async loads on live-update generation, with an
  already-loaded early-out.
- `BitmapImage`-style APIs that "load async" may still **decode on the
  UI thread at first draw** (the Mac's `NSImage(data:)` only parses
  headers) — force the raster decode in the background
  (`SetSourceAsync` off-thread / decode-pixel-width variants), or the
  thumbs stutter in together.
- The already-visible re-summon path may genuinely need the synchronous
  layout the hidden path skips — gate on visibility rather than
  removing it outright.

## Wrap-up checklist (Windows side)

- [ ] Permanent perf line + counters, mirroring the Mac fields.
- [ ] Before/after numbers in `windows/CHANGELOG.md` + version bump.
- [ ] `docs/parity.md`: flip the "Popup summon perf" row's Windows cell
      with the measured numbers.
- [ ] Note anything you find that the Mac should port back (the last
      Windows→Mac handoff pattern: `macos-wordpress-title-precedence.md`).
