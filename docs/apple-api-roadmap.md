# Apple API roadmap — capability survey (planning only)

> **Status: brainstorm, 2026-08-26.** Web-verified against current
> developer.apple.com docs (availability read from Apple's doc JSON,
> not memory; unverified claims are marked). Context: package floor is
> macOS 14, fleet is M2+, ethos is local-first / no cloud APIs / no
> subscriptions. Nothing here is committed work — it's the menu.
> Windows-analogue notes per `parity.md` culture.

## 0. Defense first — two platform threats found while surveying

**Pasteboard privacy enforcement (existential, still unfired).**
`NSPasteboard.accessBehavior` shipped in macOS 15.4 with a system
pasteboard-permission alert behind a developer-preview flag
(`EnablePasteboardPrivacyDeveloperPreview`). As of Tahoe 26 and the
macOS 27 beta notes it is **still not enforced by default** — but
Apple's release notes say "prepare your app", Apple's own new Spotlight
clipboard history is prompt-exempt while third parties won't be, and
there are no MDM controls yet. When the switch flips, every background
poll cpdb does can throw an iOS-style prompt. Defensive workstream,
testable today under the preview flag:
- Query `accessBehavior` at launch; build the always-allow onboarding
  path; pause-capture + banner when `.ask`/`.deny`.
- Use `detectPatterns(for:)`/`detectValues(for:)` (15.4) to classify
  pasteboard content **without a read** — documented as alert-free.
- Harden the hygiene story: `IsSecureEventInputEnabled()` check before
  capture, full `org.nspasteboard.ConcealedType` respect (extends the
  existing `TransientGuard`), per-app exclusion lists. Windows twin:
  `ExcludeClipboardContentFromMonitorProcessing` (already honored).
- A Control Center "pause capture" `ControlWidget` (26) pairs with it.

**macOS 27 cross-team container denial (importer risk).** Golden Gate
denies cross-app container access by default with **no prompt** (user
must flip Privacy & Security manually) and blocks direct TCC reads.
The Paste.db importer reads `com.wiheads.paste`'s container — test on
the 27 beta before fall; likely needs an open-panel grant flow.

**Competitive fact:** macOS 26/26.1 ships a built-in Spotlight
clipboard history (text-oriented, 30min–7d retention, no pins/search
depth, prompt-exempt). cpdb's moat = unlimited retention, OCR'd
images, FTS5 scopes, pins, sync, Windows. Position accordingly; the
App Intents bridge below turns Spotlight into a funnel instead of a
competitor.

## 1. Ship-now tier (works on the current macOS 14 floor)

| Capability | API (min OS) | cpdb feature | Win analogue |
|---|---|---|---|
| **Semantic search** | `NLContextualEmbedding` (14) + Accelerate/vDSP cosine | THE headline: embed every text clip (512-dim, chunk >256 tokens, mean-pool) into a BLOB column; hybrid rank with FTS5 via RRF. 10k vectors ≈ 20 MB, brute-force query <1ms on M2 — no vector DB, no ANN, exact. Schema gets `model_id`+`revision` per vector so re-embedding is a background migration (hash-v2 pattern). Honest: 2023-era BERT quality — big upgrade over keyword-only, upgrade path in §4. | ONNX Runtime + MiniLM/EmbeddingGemma — real parity |
| QR/barcodes in images | `VNDetectBarcodesRequest` (10.13) | Ingest-time scan; QR URL → first-class link entry (feeds the existing enrichment), payload text → FTS5. Cheap, high-signal. | ZXing.Net |
| Smart action chips | `NSDataDetector` (10.7); `DataDetection` typed matches (12, **verify macOS scan entry point**) | Dates→Calendar, addresses→Maps, tracking numbers→carrier, flight numbers, money amounts — chips on cards, detected once at capture. | regex + carrier URL templates |
| "Paste subject only" | `VNGenerateForegroundInstanceMaskRequest` (14) | Background-removed PNG transform on image entries (Finder Copy Subject, but for history). Strong on photos, weak on busy screenshots. | ONNX RMBG/u2net |
| Live Text on cards | VisionKit `ImageAnalyzer`/`ImageAnalysisOverlayView` (13) | Select/copy text and click QR codes directly inside stored screenshots (interactive, complements the batch OCR). Runtime-check `isSupported`. | none (PowerToys Text Extractor culturally) |
| **CKSyncEngine** | (14) | Replace the hand-rolled token/scheduling/retry machinery; keeps app-chosen content-addressed record IDs and surfaces conflicts for our LWW code instead of deciding. Community-verified mature; gotchas: one engine per DB, deletions bypass conflict metadata, ~1MB batches. Migration must preserve zone/tokens or accept one clean re-sync. Do it **when sync next needs surgery**, not as a project of its own. | n/a (Windows sync = relay track) |
| Touch ID-locked clips | `LAContext`/`LARightStore` (13) | Protected clips (auto-suggested when secret-shaped): preview/paste requires biometric; LARight can gate the encryption key. Synergy with concealed-type detection. | Windows Hello `UserConsentVerifier` |
| Sweep efficiency | `NSBackgroundActivityScheduler` + `thermalState`/low-power (10.10+) | Run OCR/tag/embedding sweeps in system-coalesced windows on efficiency cores. (Verified: BGTaskScheduler macOS parity is **not coming** — BGContinuedProcessingTask is iOS-only.) | EcoQoS + Task Scheduler idle |
| Services capture | NSServices (ancient) | "Save selection to cpdb" from any app — an alert-proof capture channel if pasteboard prompts ever land. | Send-to |
| Provenance tag | `kMDItemIsScreenCapture` xattr | Auto-tag file screenshots as such (we already store source app). | n/a |

## 2. Floor-bump tier (raise package floor 14 → 15; fleet already qualifies)

- Modern async Swift Vision API (`RecognizeTextRequest` etc.) — one
  pipeline for old + new requests; prerequisite housekeeping.
- `CalculateImageAestheticsScoresRequest` — the `isUtility` flag
  distinguishes screenshots/receipts from real photos: search scope
  ("photos only") + retention policy (expire utility junk sooner).
- Saliency-driven thumbnail crops (legacy VN API works on 14 anyway).
- `TranslationSession` (15) — offline translate-clip-in-place after
  language-pack download; the SwiftUI-free `init(installedSource:)`
  needs 26, before that the popup must host a `.translationTask`.
- Core Spotlight donation (`IndexedEntity`, 15) — clips in system
  Spotlight, deep-link back into the popup. **Opt-in** (it's clipboard
  data). Semantic matching of donated content is unproven on 15
  (forum evidence says lexical-only) — donate for surfacing, keep
  ranking in-app; same entities graduate into §4's semantic index.

## 3. macOS 26 tier (current release; Apple Intelligence gates noted)

- **`RecognizeDocumentsRequest`** (26, no AI gate) — headline #2:
  document-structure OCR with real tables (`cell(row:col:)`), lists,
  paragraphs + barcodes in one pass. Screenshot of a table → **"Paste
  as CSV/Markdown"**. Real-world: clean grids parse well, merged cells
  degrade — ship with a preview step. Windows: none (WinRT OCR is
  plain text) — a genuine Mac-only differentiator.
- **`SpeechAnalyzer`/`SpeechTranscriber`** (26, **no AI gate**) —
  transcribe audio/video clips in the analysis sweep into FTS5, same
  pattern as OCR. Mid-Whisper accuracy, much faster, offline.
  Windows: whisper.cpp/ONNX.
- **Foundation Models** (26, AI-gated — availability-check + hide):
  - `SystemLanguageModel(useCase: .contentTagging)` — cheapest FM win:
    semantic topic tags for text clips into the tag column.
  - Auto-title + one-line summary for long clips (into FTS5).
  - `@Generable` NL query parsing: "that docker thing from last week"
    → typed SearchFilter → FTS5. Constrained decoding = no parse
    failures. 4,096-token context (26.0 has `contextSize`; 26.4 adds
    `tokenCount(for:)`) — budget before prompting, retrieval via Tool
    calling, never context-stuffing.
  - Design constraint: single `AIService` facade returning nil below
    26 / when Apple Intelligence is off; NLTagger as the pre-26 tag
    fallback. Windows analogue: Phi Silica (Copilot+ NPU only — parity
    will lag; note it per-feature).
- **App Intents surface** (26): SearchClips / PasteLatest / PasteNth /
  PinClip intents → Spotlight actions with inline parameters + Quick
  Keys + Shortcuts; the "Use Model" Shortcuts action then gives users
  BYO-model AI over clips with zero AI code shipped. macOS 26's
  built-in clipboard history trains the muscle memory; our intents
  catch it. Test via the new App Intents Testing Framework (Xcode 27).
- `ControlWidget` (26): pause-capture toggle + open-popup in Control
  Center/menu bar. Writing Tools come free in any NSTextView (15.2).

## 4. macOS 27 frontier (beta now, ships ~this fall)

- **Core AI framework** (27, no AI gate stated) — run OUR OWN models
  on the ANE: PyTorch → `coreai-build` AOT → Background Assets
  download. Apple explicitly names "embedding models" as the use case
  — this is the quality ceiling-raiser for §1 semantic search
  (EmbeddingGemma-class replacing NLContextualEmbedding; the
  `model_id`/`revision` column makes it a background re-embed).
- **Foundation Models goes provider-agnostic** (27β): public
  `LanguageModel` protocol — same session/@Generable/Tool code runs
  Apple on-device, an MLX community model, Core AI export, Private
  Cloud Compute (32k context, free under 2M downloads, managed
  entitlement), or user-keyed Claude/Gemini. A "bring your own model"
  power knob is exactly on-brand.
- **`SpotlightSearchTool`** (27β) — Apple's blessed "ask your
  clipboard" RAG: LLM searches our donated Spotlight index and
  reasons over hits ("the Wi-Fi password I copied at the Airbnb").
  Requires §2's donation groundwork; supersedes worrying about
  CSUserQuery quality.
- **App Schemas + semantic Spotlight index** (27) — donated entities
  join the rebuilt OS semantic index; no clipboard domain exists, so
  we ride general App Intents + IndexedEntity. **View Annotations**:
  Siri resolves "paste the second one" against visible popup rows —
  purpose-built for list UIs like ours.
- `GenerateIterativeSegmentationRequest` (27β) — click/lasso-to-lift
  exactly one object from a stored screenshot (SAM-style,
  model-download gated).
- FM `Attachment` image prompting (27β) — auto-describe screenshots
  for search, @Generable extraction from receipts/tables in images.
- Toolchain notes: Xcode 27 is Apple-silicon-only; Liquid Glass
  adoption is automatic-and-mandatory when building against the 27
  SDK (UI tax on the popup); Vision arrived on watchOS (irrelevant,
  noted for completeness).

## Recommended attack order (if/when this becomes work)

1. **Pasteboard-privacy preparedness** (§0) — existential, testable
   today, also the best trust story. Includes concealed/secure-input
   hygiene (cross-platform win, exact Windows analogue).
2. **Semantic search** on NLContextualEmbedding + FTS5 hybrid (§1) —
   biggest user-visible leap, works on the whole fleet today, schema
   designed for the Core AI upgrade. Windows parity real via ONNX.
3. **QR ingest + data-detector chips** (§1) — small, immediately
   delightful, easy Windows parity.
4. **Table→CSV paste** via RecognizeDocumentsRequest (§3) — headline
   differentiator, no AI gate, needs macOS 26 at runtime (gate per
   entry, feature-flag below).
5. **App Intents + Spotlight** (§2/§3) — distribution more than
   feature; rides the OS's own clipboard-history muscle memory.
6. **CKSyncEngine** (§1) — opportunistic, next time sync needs work.
7. **FM enrichment** (contentTagging → titles → NL queries) (§3) —
   after the facade exists; strictly additive, gated, degradable.
8. **Transcription sweep** (§3) — when audio/video clips prove common
   enough to matter (measure first).

Honest NOs surfaced by the survey: FSKit history-volume (block-device
only — though Windows could do it via ProjFS someday), SwiftData
migration (still no FTS5; GRDB stays), waiting for macOS
BGTaskScheduler parity (confirmed not coming), sentiment analysis on
clipboard content (useless), lens-smudge detection (n/a).
