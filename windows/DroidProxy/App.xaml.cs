using System.Windows.Input;
using DroidProxy.Daemon;
using Microsoft.Win32;
using H.NotifyIcon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace DroidProxy;

/// <summary>
/// Owns the daemon process, the control-API client, and the tray icon.
/// The window is a view on the daemon state streamed from /v1/events.
/// </summary>
public partial class App : Application
{
    private sealed class RelayCommand(Action action) : ICommand
    {
        public event EventHandler? CanExecuteChanged { add { } remove { } }
        public bool CanExecute(object? parameter) => true;
        public void Execute(object? parameter) => action();
    }

    private Window? _window;
    private TaskbarIcon? _tray;
    private CancellationTokenSource? _watchCts;

    public App()
    {
        InitializeComponent();
        Host = new DaemonHost();
        Client = new DaemonClient(Host.SocketPath);
    }

    public static new App Current => (App)Application.Current;
    public DaemonHost Host { get; }
    public DaemonClient Client { get; }
    public bool IsQuitting { get; private set; }

    /// <summary>Raised on a background thread; null means the daemon is offline.</summary>
    public event Action<DaemonState?>? StateChanged;

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        Host.Start();
        _watchCts = new CancellationTokenSource();
        _ = WatchLoopAsync(_watchCts.Token);
        try
        {
            CreateTrayIcon();
        }
        catch
        {
            // No shell notification area (e.g. a non-interactive session):
            // the window still works without the tray icon.
        }
        _window.Activate();
    }

    // Launch-at-login is owned by the app on Windows (the daemon's systemd
    // path refuses there): a per-user Run entry pointing at this exe.
    public static bool IsLaunchAtLoginEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        return key?.GetValue("DroidProxy") is string;
    }

    public static void SetLaunchAtLogin(bool enabled)
    {
        using var key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run");
        if (enabled)
        {
            var exe = Environment.ProcessPath;
            if (exe is not null) key.SetValue("DroidProxy", $"\"{exe}\"");
        }
        else
        {
            key.DeleteValue("DroidProxy", throwOnMissingValue: false);
        }
    }

    public void ShowMainWindow()
    {
        if (_window is null) return;
        _window.AppWindow.Show();
        _window.Activate();
    }

    public async Task QuitAsync()
    {
        IsQuitting = true;
        _watchCts?.Cancel();
        _tray?.Dispose();
        await Host.StopAsync();
        Exit();
    }

    private async Task WatchLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Client.WatchAsync(state =>
                {
                    StateChanged?.Invoke(state);
                    return Task.CompletedTask;
                }, cancellationToken);
            }
            catch (DaemonClient.OfflineException)
            {
                StateChanged?.Invoke(null);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                StateChanged?.Invoke(null);
            }
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
        }
    }

    private void CreateTrayIcon()
    {
        var openItem = new MenuFlyoutItem { Text = "Open DroidProxy" };
        openItem.Click += (_, _) => ShowMainWindow();
        var toggleItem = new MenuFlyoutItem { Text = "Start/Stop Server" };
        toggleItem.Click += async (_, _) =>
        {
            try { await Client.CallAsync("server.toggle"); }
            catch (DaemonClient.OfflineException) { Host.Start(); }
        };
        var quitItem = new MenuFlyoutItem { Text = "Quit" };
        quitItem.Click += async (_, _) => await QuitAsync();

        var menu = new MenuFlyout();
        menu.Items.Add(openItem);
        menu.Items.Add(toggleItem);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(quitItem);

        _tray = new TaskbarIcon
        {
            ToolTipText = "DroidProxy",
            IconSource = new BitmapImage(new Uri("ms-appx:///Assets/AppIcon.ico")),
            ContextFlyout = menu,
            DoubleClickCommand = new RelayCommand(ShowMainWindow),
        };
        _tray.ForceCreate();
    }
}
