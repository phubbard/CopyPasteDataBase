using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;
using WinRT;

namespace CpdbWin.App;

/// <summary>
/// Custom Main so Velopack's bootstrapper can intercept install / update /
/// uninstall command-line invocations BEFORE WinUI initialises. The XAML
/// auto-generated Main is suppressed via DISABLE_XAML_GENERATED_MAIN in
/// CpdbWin.App.csproj.
///
/// The boilerplate after VelopackApp.Build().Run() mirrors what the
/// auto-generated Main does for an unpackaged WinUI 3 app — initialise
/// COM wrappers, start the WinUI application loop, hand off to
/// <see cref="App"/>.
/// </summary>
public static class Program
{
    [System.STAThread]
    public static int Main(string[] args)
    {
        // Velopack hooks: when Setup.exe / squirrel-flavoured commands
        // invoke our exe with --veloapp-* args, Run() handles the
        // install/uninstall/update lifecycle and exits without ever
        // showing the UI. On a normal launch it returns immediately.
        VelopackApp.Build().Run();

        ComWrappersSupport.InitializeComWrappers();
        Application.Start((p) =>
        {
            var ctx = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(ctx);
            _ = new App();
        });
        return 0;
    }
}
