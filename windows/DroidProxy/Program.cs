using Microsoft.UI.Dispatching;
using Velopack;

namespace DroidProxy;

public static class Program
{
    // Replaces the XAML-generated Main (DISABLE_XAML_GENERATED_MAIN) so Velopack runs its
    // install, update and uninstall hooks before any window exists.
    [STAThread]
    private static void Main()
    {
        VelopackApp.Build()
            .OnBeforeUninstallFastCallback(_ => App.SetLaunchAtLogin(false))
            .Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Microsoft.UI.Xaml.Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
    }
}
