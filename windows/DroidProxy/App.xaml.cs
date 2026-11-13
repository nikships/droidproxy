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

    public App()
    {
        InitializeComponent();
        Host = new DaemonHost();
        Client = new DaemonClient(Host.SocketPath);
        ViewModel = new AppViewModel(Host, Client);
    }

    public static new App Current => (App)Application.Current;
    public DaemonHost Host { get; }
    public DaemonClient Client { get; }
    public AppViewModel ViewModel { get; }
    public bool IsQuitting { get; private set; }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        Host.Start();
        try
        {
            CreateTrayIcon();
        }
        catch
        {
            // No shell notification area (e.g. a non-interactive session):
            // the window still works without the tray icon.
        }
        ViewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(AppViewModel.Status) or nameof(AppViewModel.StatusText)) UpdateTray();
        };
        _watchCts = new CancellationTokenSource();
        _ = WatchLoopAsync(_window.DispatcherQueue, _watchCts.Token);
        _ = ViewModel.RefreshAsync();
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

    public async Task QuitAsync()
    {
        IsQuitting = true;
        _watchCts?.Cancel();
        _tray?.Dispose();
        await Host.StopAsync();
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
                }, cancellationToken);
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
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => onClick();
            return item;
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
