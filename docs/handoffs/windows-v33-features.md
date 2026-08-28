# Hand-off: v3.3 features — Windows ports (semantic search, chips, QR)

> **Origin:** macOS/iOS cpdb 3.3.0 (2026-08-28). Six features shipped;
> three have real Windows parity paths, listed by value. The Mac
> implementations to mirror: Sources/CpdbShared/Analysis/
> {EmbeddingService,EmbeddingIndex,EmbeddingSweeper}.swift,
> TextChipDetector + chip UI in the popup cards, ImageIndexer's
> barcode pass. Schema: v12_semantic_enrichment + v14_recency_index
> (see Schema.swift; Windows migrator numbers独立 — next free slot).

## 1. Semantic search (the big one)
- Embed text/link entries at capture + backlog sweep; store per-entry
  vectors (`entry_embeddings`: model_id, revision, dims, vector BLOB
  Float32-LE L2-normalized) + hybrid rank: RRF(k=60) over FTS5 rank
  and cosine rank, similarity floor 0.35, topK 50.
- Windows engine: ONNX Runtime + a small sentence-transformer
  (all-MiniLM-L6-v2 384-dim or EmbeddingGemma-class). DirectML EP
  where available, CPU EP otherwise. The model_id/revision columns
  exist precisely so each platform can use its own model — vectors
  are per-device-family; do NOT compare Mac vectors with Windows
  vectors (different models). Simplest correct stance: Windows
  computes its own vectors for all entries (it's standalone anyway).
- Brute-force search: 10k × 384 float32 ≈ 15 MB; one query =
  System.Numerics.Tensors dot products, sub-ms. No vector DB.
- Also port the v14 lesson: ensure an index matches the popup's
  recency ORDER BY before the enrichment columns fatten rows.

## 2. Action chips
- Scan at capture + backfill pass; store `chips_json` (same JSON
  shape: [{"t":"date|address|phone|url|tracking|flight|money",
  "v":value,"s":display}]). Windows has no NSDataDetector: regex
  table for dates/phones/tracking (UPS/FedEx/USPS patterns are in
  the Mac TextChipDetector — copy them), `Windows.Data.Text` or
  simple URL parsing for links. Chip actions: outlook/ics for dates,
  maps URL, tel:, carrier URLs.

## 3. QR codes in screenshots
- ZXing.Net pass inside the existing OCR sweep; QR URL payloads →
  chips (t:"url"). Cheap, same UX as Mac.

## Not portable (note in parity, skip)
- Copy-as-Table (Vision document OCR — WinRT OCR has no structure;
  revisit if a local table-structure model ever earns its keep).
- Foundation Models auto-titles (Phi Silica is Copilot+-only; skip
  until the general Windows fleet can run it).
- Pasteboard-privacy prep (no Windows clipboard permission model).
- App Intents/Spotlight (Windows analogue would be PowerToys Command
  Palette — separate, optional project).
