using System.Security.Cryptography;
using System.Text;
using System.Windows.Input;
using DroidProxy.Daemon;
using Microsoft.Win32;
using H.NotifyIcon;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace DroidProxy;

/// <summary>
/// Owns the daemon process, the control-API client, the view model and the
/// tray icon. Snapshots streamed from /v1/events are applied to the view
/// model on the UI thread; every window and the tray bind to it.
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
    private MenuFlyoutItem? _trayStatus;
    private MenuFlyoutItem? _trayStartStop;
    private string? _trayIconName;
    private CancellationTokenSource? _watchCts;
    private Mutex? _instance;

    public App()
    {
        InitializeComponent();
        Host = new DaemonHost();
        Client = new DaemonClient(Host.SocketPath);
        ViewModel = new AppViewModel(Host, Client);
    }

    public UpdatesViewModel Updates { get; } = new();

    public static new App Current => (App)Application.Current;
    public DaemonHost Host { get; }
    private DaemonClient Client { get; }
    public AppViewModel ViewModel { get; }
    public bool IsQuitting { get; private set; }
    public bool HasTray => _tray is not null;

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        // Two apps on one socket would each start a daemon and fight over it. Keying on the
        // socket lets a dev build attached to the fake daemon run beside the installed app.
        var socketHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Host.SocketPath.ToLowerInvariant())));
        _instance = new Mutex(true, $"DroidProxy-{socketHash[..16]}", out var first);
        if (!first)
        {
            Exit();
            return;
        }
        _window = new MainWindow();
        Host.Start();
        try
        {
            CreateTrayIcon();
        }
        catch
        {
            // No shell notification area (e.g. a non-interactive session):
            // the window still works, and closing it quits.
            _tray?.Dispose();
            _tray = null;
        }
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppViewModel.Status) or nameof(AppViewModel.StatusText)) UpdateTray();
        };
        _watchCts = new CancellationTokenSource();
        _ = WatchLoopAsync(_window.DispatcherQueue, _watchCts.Token);
        _ = ViewModel.RefreshAsync();
        _ = Updates.RunAsync(_watchCts.Token);
        // An entry written by a manual copy or an older build moves to the install's stable launcher.
        if (UpdatesViewModel.StableExe is not null && IsLaunchAtLoginEnabled()) SetLaunchAtLogin(true);
        _window.Activate();
    }

    // Launch-at-login is owned by the app on Windows (the daemon's systemd
    // path refuses there): a per-user Run entry pointing at the installed
    // launcher, or at this exe when not installed.
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
            var exe = UpdatesViewModel.StableExe ?? Environment.ProcessPath;
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

    public async Task<bool> ConfirmAsync(string title, string content, string primary)
    {
        if (_window?.Content.XamlRoot is not { } root) return false;
        var dialog = new ContentDialog
        {
            Title = title,
            Content = content,
            PrimaryButtonText = primary,
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = root,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    /// <param name="beforeExit">Runs once the daemon has stopped, e.g. to hand over to the updater.</param>
    public async Task QuitAsync(Action? beforeExit = null)
    {
        IsQuitting = true;
        _watchCts?.Cancel();
        _tray?.Dispose();
        await Host.StopAsync();
        beforeExit?.Invoke();
        Exit();
    }

    private async Task WatchLoopAsync(DispatcherQueue ui, CancellationToken cancellationToken)
    {
        void Publish(DaemonState? state) => ui.TryEnqueue(() => ViewModel.Apply(state));
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                await Client.WatchAsync(state =>
                {
                    Publish(state);
                    return Task.CompletedTask;
                }, (body, isError) => ui.TryEnqueue(() => ViewModel.ShowDaemonMessage(body, isError)), cancellationToken);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch
            {
                Publish(null);
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
        MenuFlyoutItem Item(string text, Action onClick)
        {
            // H.NotifyIcon's default PopupMenu mode runs Command and ignores Click.
            return new MenuFlyoutItem { Text = text, Command = new RelayCommand(onClick) };
        }
        _trayStatus = new MenuFlyoutItem { IsEnabled = false };
        _trayStartStop = Item("", ViewModel.StartStop);
        var menu = new MenuFlyout();
        menu.Items.Add(_trayStatus);
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Open DroidProxy", ShowMainWindow));
        menu.Items.Add(_trayStartStop);
        menu.Items.Add(Item("Copy server URL", ViewModel.CopyUrl));
        menu.Items.Add(Item("Open dashboard", ViewModel.OpenDashboard));
        menu.Items.Add(new MenuFlyoutSeparator());
        menu.Items.Add(Item("Quit", async () => await QuitAsync()));

        _tray = new TaskbarIcon
        {
            ContextFlyout = menu,
            DoubleClickCommand = new RelayCommand(ShowMainWindow),
        };
        UpdateTray();
        _tray.ForceCreate();
    }

    private void UpdateTray()
    {
        if (_tray is null) return;
        var vm = ViewModel;
        _trayStatus!.Text = $"Server: {vm.StatusText}";
        _trayStartStop!.Text = vm.StartStopLabel;
        _tray.ToolTipText = $"DroidProxy · {vm.StatusText}";
        // The glyph is monochrome, so it follows the taskbar theme rather than the app theme.
        using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        var taskbar = key?.GetValue("SystemUsesLightTheme") is 1 ? "light" : "dark";
        var name = $"tray-{taskbar}-{(vm.IsRunning ? "active" : "inactive")}.ico";
        if (name == _trayIconName) return;
        _trayIconName = name;
        _tray.IconSource = new BitmapImage(new Uri($"ms-appx:///Assets/Tray/{name}"));
    }
}
