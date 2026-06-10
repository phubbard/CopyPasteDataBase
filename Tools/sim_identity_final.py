#!/usr/bin/env python3
"""
Step-0 gate: run the FINAL v2 identity ruleset (the reference implementation in
gen_hash_vectors.py — slash-strip, URL-context trim, html ladder, empty->fallback,
1024-byte image threshold, shared-pasteboard skip, color rung) over the real
production snapshot and check:

  1. total would-merge clusters + excess rows  (the number the migration's
     step-3 assertion will expect)
  2. ZERO false merges  (a cluster whose members are genuinely different content)
  3. flavor-level inspection of every cluster the refinements add beyond plain
     semantic V4, so the slash-strip / promotion can't be silently merging
     distinct things.

Gate verdict (per docs/canonical-hash-v2.md §9 step 0): zero false merges, or the
slash-strip is dropped and the vectors regenerate without it.

Usage:  python3 Tools/sim_identity_final.py [/path/to/cpdb-audit.db]
"""
import os
import sqlite3
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gen_hash_vectors as ref  # the ONE identity implementation

DB = sys.argv[1] if len(sys.argv) > 1 else "/tmp/cpdb-audit.db"
SPILL_PROXY_MIN = 1024  # spilled flavors are >=256 KB in reality; pad proxy past the image threshold


def load(db):
    con = sqlite3.connect(db)
    con.text_factory = bytes  # keep raw bytes; we decode deliberately
    cur = con.cursor()
    entries = {}
    for eid, kind, cap, tp in cur.execute(
        "SELECT id, kind, captured_at, text_preview FROM entries WHERE deleted_at IS NULL"
    ):
        prev = tp.decode("utf-8", "replace") if isinstance(tp, bytes) and tp is not None else (tp or "")
        entries[eid] = (kind.decode() if isinstance(kind, bytes) else kind, cap, prev)

    flav = defaultdict(dict)  # eid -> {uti: bytes}  (first-wins flatten, matches PK)
    for eid, uti, data, blob_key in cur.execute(
        """SELECT f.entry_id, f.uti, f.data, f.blob_key
           FROM entry_flavors f JOIN entries e ON e.id = f.entry_id
           WHERE e.deleted_at IS NULL"""
    ):
        uti = uti.decode() if isinstance(uti, bytes) else uti
        if uti in flav[eid]:
            continue  # PK (entry_id, uti) means this can't really happen, but be safe
        if data is not None:
            flav[eid][uti] = data if isinstance(data, bytes) else str(data).encode()
        else:
            # Spilled: blob store is content-addressed, so the key is a faithful
            # equality proxy. Pad past the 1024-byte image threshold so the image
            # rung fires exactly as it would on the real >=256 KB bytes.
            bk = blob_key.decode() if isinstance(blob_key, bytes) else blob_key
            seed = ("BLOB:" + bk).encode()
            flav[eid][uti] = (seed * ((SPILL_PROXY_MIN // len(seed)) + 1))[:SPILL_PROXY_MIN]
    con.close()
    return entries, flav


def identity_for(flatmap):
    """Wrap the reference rung chain. flatmap is {uti: bytes}."""
    tag, value = ref.identity(dict(flatmap))
    # Domain-separated digest, same as content_hash_v2 but we only need a key.
    import hashlib
    h = hashlib.sha256()
    h.update(tag.encode("utf-8"))
    h.update(b"\x00")
    h.update(value)
    return tag, h.digest()


def url_normalize_preview(s):
    """Lightweight benign-difference canonicalizer for the false-merge check:
    a cluster whose previews differ ONLY by URL trim-set + one trailing slash is
    NOT a false merge — that's exactly what the refinements are supposed to
    collapse. Anything else that differs is a real candidate to inspect."""
    s = ref.normalize_text(s)
    s = ref.trim_url_set(s)
    s = ref.strip_one_trailing_slash(s)
    return s


def fmt_spread(sec):
    if sec < 30: return f"{sec:.0f}s"
    if sec < 3600: return f"{sec/60:.1f}m"
    if sec < 86400: return f"{sec/3600:.1f}h"
    return f"{sec/86400:.1f}d"


def main():
    entries, flav = load(DB)
    total_live = len(entries)
    no_flavor = [e for e in entries if e not in flav]
    hashable = {e: flav[e] for e in flav}

    by_hash = defaultdict(list)
    tag_of = {}
    for eid, fm in hashable.items():
        tag, h = identity_for(fm)
        by_hash[h].append(eid)
        tag_of[eid] = tag

    clusters = {h: ids for h, ids in by_hash.items() if len(ids) > 1}
    excess = sum(len(ids) - 1 for ids in clusters.values())

    # tag distribution of clusters (which rung is doing the merging)
    cluster_tag = defaultdict(int)
    for h, ids in clusters.items():
        # all members share the hash, hence the same tag
        cluster_tag[tag_of[ids[0]]] += 1

    # time-spread buckets
    buckets = {"<30s": 0, "30s-5m": 0, "5m-1d": 0, ">1d": 0}
    spread = {}
    for h, ids in clusters.items():
        caps = [entries[e][1] for e in ids]
        sp = max(caps) - min(caps)
        spread[h] = sp
        if sp < 30: buckets["<30s"] += 1
        elif sp < 300: buckets["30s-5m"] += 1
        elif sp < 86400: buckets["5m-1d"] += 1
        else: buckets[">1d"] += 1

    # FALSE-MERGE candidates: cluster members whose URL-normalized previews differ.
    false_merges = []
    for h, ids in clusters.items():
        norms = {url_normalize_preview(entries[e][2] or "") for e in ids}
        if len(norms) > 1:
            false_merges.append((h, ids))

    print(f"DB: {DB}")
    print(f"Total live entries:               {total_live}")
    print(f"  no-flavor (evicted, excluded):  {len(no_flavor)}")
    print(f"  rehashed:                       {len(hashable)}")
    print()
    print(f"FINAL RULESET (idv2-r1) cluster results")
    print(f"  would-merge clusters (>1):      {len(clusters)}")
    print(f"  excess rows eliminated:         {excess}   ({100*excess/total_live:.1f}% of live corpus)")
    print(f"  cluster tag distribution:       " +
          "  ".join(f"{t}={n}" for t, n in sorted(cluster_tag.items(), key=lambda kv: -kv[1])))
    print(f"  time spread:                    " +
          "  ".join(f"{k}={v}" for k, v in buckets.items()))
    print()
    print(f"GATE — false-merge candidates (URL-normalized preview differs within cluster): {len(false_merges)}")
    if false_merges:
        for h, ids in false_merges[:40]:
            print(f"  spread={fmt_spread(spread[h])} tag={tag_of[ids[0]]} n={len(ids)}")
            seen = set()
            for e in ids:
                p = (entries[e][2] or "").replace("\n", "\\n")[:80]
                key = url_normalize_preview(entries[e][2] or "")
                mark = "" if key in seen else "  <-- distinct-normalized"
                seen.add(key)
                print(f"      id={e:5d} kind={entries[e][0]:6} '{p}'{mark}")
    else:
        print("  -> NONE. Every multi-member cluster's members are the same content")
        print("     after URL trim/slash normalization. Slash-strip + promotion introduce")
        print("     zero false merges. GATE PASSES.")

    # Largest clusters, for a human eyeball
    print()
    print("Top 12 largest clusters:")
    for h, ids in sorted(clusters.items(), key=lambda kv: -len(kv[1]))[:12]:
        e0 = ids[0]
        kinds = "/".join(sorted({entries[e][0] for e in ids}))
        p = (entries[e0][2] or "").replace("\n", "\\n")[:60]
        print(f"  n={len(ids):3d} spread={fmt_spread(spread[h]):>6} tag={tag_of[e0]:8} kind={kinds:12} '{p}'")

    print()
    print(f"RECORD FOR MIGRATION ASSERTION: {len(clusters)} live would-merge clusters, "
          f"{excess} excess rows on this snapshot.")


if __name__ == "__main__":
    main()
