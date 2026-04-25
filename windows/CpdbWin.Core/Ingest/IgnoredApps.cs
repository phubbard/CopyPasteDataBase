using CpdbWin.Core.Identity;

namespace CpdbWin.Core.Ingest;

/// <summary>
/// Bundle-id blocklist for capture. When the foreground app at copy time
/// matches, the snapshot never lands in the database — the alternative
/// would be leaking credentials into plain-text history and the FTS5
/// index.
///
/// Defaults cover the three managers from plan.md (1Password, Bitwarden,
/// KeePass). The bundle-id convention <c>win.&lt;exe-stem&gt;</c> from
/// docs/schema.md §apps means the matches are by lowercased exe stem,
/// e.g. <c>1Password.exe</c> → <c>win.1password</c>.
/// </summary>
public sealed class IgnoredApps
{
    public static IReadOnlySet<string> DefaultBundleIds { get; } =
        new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            "win.1password",
            "win.bitwarden",
            "win.keepass",
        };

    private readonly HashSet<string> _bundleIds;

    public IgnoredApps()
        : this(DefaultBundleIds)
    { }

    public IgnoredApps(IEnumerable<string> bundleIds)
    {
        _bundleIds = new HashSet<string>(bundleIds, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Build a set that adds the user's extras to the defaults.</summary>
    public static IgnoredApps WithUserExtras(IEnumerable<string> extras)
        => new(DefaultBundleIds.Concat(extras));

    public IReadOnlyCollection<string> BundleIds => _bundleIds;

    public bool ShouldIgnore(string? bundleId)
        => !string.IsNullOrEmpty(bundleId) && _bundleIds.Contains(bundleId);

    public bool ShouldIgnore(ForegroundApp.Info? info)
        => info is { } i && ShouldIgnore(i.BundleId);
}
