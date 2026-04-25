using System.Reflection;

namespace CpdbWin.Core;

/// <summary>
/// User-visible product identity. <see cref="Number"/> is read at runtime
/// from <c>AssemblyInformationalVersionAttribute</c> (set via
/// <c>&lt;Version&gt;</c> in <c>Directory.Build.props</c>) so a single
/// edit in one place updates the title bar, tray tooltip, and any other
/// surface that displays it.
/// </summary>
public static class CpdbVersion
{
    public const string Description = "cpdb-win";

    public static string Number { get; } = ResolveVersion();

    public static string Full => $"{Description} {Number}";

    private static string ResolveVersion()
    {
        var info = typeof(CpdbVersion).Assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;
        if (string.IsNullOrWhiteSpace(info)) return "0.0.0";
        // .NET sometimes appends a +commit-sha suffix in CI builds — strip it
        // for display.
        var plus = info.IndexOf('+');
        return plus >= 0 ? info[..plus] : info;
    }
}
