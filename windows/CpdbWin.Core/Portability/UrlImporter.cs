using CpdbWin.Core.Capture;
using CpdbWin.Core.Identity;
using CpdbWin.Core.Ingest;
using System.Text;

namespace CpdbWin.Core.Portability;

/// <summary>
/// Bulk-seed the database from a list of URL strings, ingesting each
/// as if it had been copied to the clipboard so kind=link rows flow
/// through the normal backfill → title + thumbnail enrichment.
///
/// One implementation shared by <c>cpdb-win import-urls</c> and the
/// WinUI Preferences "Import…" button — per
/// <c>docs/parity.md § Data portability</c>. Pure logic over the
/// store; the caller supplies the already-read file text.
///
/// Contract (docs/parity.md § Data portability — URL-list import):
/// trim each line, drop blank + <c>#</c>-comment lines, accept only
/// <c>http</c>/<c>https</c>/<c>file</c> schemes (reject others with a
/// reason). Each accepted line becomes a synthetic snapshot with
/// <c>public.url</c> + <c>public.utf8-plain-text</c> flavors,
/// attributed to a synthetic "cpdb import" source app so seeded rows
/// are distinguishable. <c>spreadSeconds</c> backdates
/// <c>captured_at</c> (oldest line = oldest) so the import doesn't
/// collapse to one timestamp and scramble popup order.
/// </summary>
public static class UrlImporter
{
    /// <summary>
    /// Synthetic source-app identity stamped on imported rows so they
    /// are distinguishable from real captures. Mirrors macOS's
    /// <c>SourceApp.importer</c>.
    /// </summary>
    public static readonly ForegroundApp.Info ImporterApp =
        new(BundleId: "cpdb.import", Name: "cpdb import", ExePath: "");

    public readonly record struct RejectedLine(string Line, string Reason);

    public sealed class Result
    {
        public int Inserted { get; set; }
        public int Bumped { get; set; }
        public int Skipped { get; set; }
        public int AcceptedCount { get; set; }
        public List<RejectedLine> Rejected { get; } = new();
    }

    /// <summary>
    /// Parse raw file text into accepted URLs + rejection reasons.
    /// Blank lines and <c>#</c>-comments are dropped; only
    /// http(s)/file schemes are accepted. Separated from
    /// <see cref="Run"/> so a dry-run / preview can show the plan
    /// without touching the store.
    /// </summary>
    public static (List<string> Accepted, List<RejectedLine> Rejected) Parse(string raw)
    {
        var accepted = new List<string>();
        var rejected = new List<RejectedLine>();

        // omittingEmptySubsequences=false equivalent: split on \n keeping
        // empties, then trim + filter, so a trailing newline or blank
        // lines between entries don't shift indices.
        foreach (var rawLine in raw.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;

            if (!Uri.TryCreate(line, UriKind.Absolute, out var u))
            {
                rejected.Add(new RejectedLine(line, "unparseable"));
                continue;
            }
            var scheme = u.Scheme.ToLowerInvariant();
            if (scheme is not ("http" or "https" or "file"))
            {
                rejected.Add(new RejectedLine(line, $"scheme '{scheme}' not http/https/file"));
                continue;
            }
            accepted.Add(line);
        }
        return (accepted, rejected);
    }

    /// <summary>
    /// Ingest <paramref name="rawText"/>. <paramref name="spreadSeconds"/>
    /// spreads <c>captured_at</c> backwards from
    /// <paramref name="now"/> (oldest line = oldest) so the import
    /// doesn't collapse into a single timestamp.
    /// </summary>
    public static Result Run(
        string rawText,
        Ingestor ingestor,
        DeviceIdentity.Info device,
        double spreadSeconds = 0,
        DateTimeOffset? now = null)
    {
        var (accepted, rejected) = Parse(rawText);
        var result = new Result { AcceptedCount = accepted.Count };
        result.Rejected.AddRange(rejected);
        if (accepted.Count == 0) return result;

        var nowDto = now ?? DateTimeOffset.UtcNow;
        // Spread each accepted line evenly across the window: the
        // oldest (first) line is `spreadSeconds` before now, the
        // newest (last) line is now.
        var step = spreadSeconds / Math.Max(accepted.Count, 1);

        for (int idx = 0; idx < accepted.Count; idx++)
        {
            var offset = step * (accepted.Count - 1 - idx);
            var capturedAt = nowDto.AddSeconds(-offset);
            var snapshot = Snapshot(accepted[idx]);
            var outcome = ingestor.Ingest(snapshot, ImporterApp, device, capturedAt);
            switch (outcome.Kind)
            {
                case IngestKind.Inserted: result.Inserted++; break;
                case IngestKind.Bumped:   result.Bumped++;   break;
                case IngestKind.Skipped:  result.Skipped++;  break;
            }
        }
        return result;
    }

    /// <summary>
    /// Synthetic clipboard snapshot for a URL string:
    /// <c>public.url</c> (so the kind classifier resolves
    /// <c>link</c>) + <c>public.utf8-plain-text</c> (so search /
    /// text_preview behave like a real browser copy).
    /// </summary>
    public static ClipboardSnapshot Snapshot(string urlString)
    {
        var bytes = Encoding.UTF8.GetBytes(urlString);
        return new ClipboardSnapshot(new[]
        {
            new CanonicalHash.Flavor("public.url", bytes),
            new CanonicalHash.Flavor("public.utf8-plain-text", bytes),
        });
    }
}
