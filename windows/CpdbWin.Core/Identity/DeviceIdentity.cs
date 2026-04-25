using Microsoft.Win32;

namespace CpdbWin.Core.Identity;

/// <summary>
/// Stable machine identity for the <c>devices</c> table. Identifier comes
/// from <c>HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid</c> per
/// docs/schema.md §devices — same key every Microsoft tool uses for a
/// per-install ID. Falls back to a synthesized id derived from MachineName
/// if the registry read fails (e.g. sandboxed test runner, locked-down VDI).
/// </summary>
public static class DeviceIdentity
{
    public readonly record struct Info(string Identifier, string Name, string Kind);

    public static Info Read()
    {
        var identifier = ReadMachineGuid() ?? $"win-fallback-{Environment.MachineName}";
        return new Info(identifier, Environment.MachineName, "win");
    }

    private static string? ReadMachineGuid()
    {
        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Cryptography");
            return key?.GetValue("MachineGuid") as string;
        }
        catch
        {
            return null;
        }
    }
}
