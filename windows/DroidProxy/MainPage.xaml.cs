using DroidProxy.Daemon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

/// <summary>
/// Status view over the daemon snapshot: server state, version, and the
/// provider/account summary. Actions go through the control API, the same
/// contract the Omarchy panel uses.
/// </summary>
public sealed partial class MainPage : Page
{
    private DaemonState? _state;

    public MainPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        App.Current.StateChanged += OnStateChanged;
        _ = RefreshAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e)
    {
        App.Current.StateChanged -= OnStateChanged;
    }

    private void OnStateChanged(DaemonState? state)
    {
        DispatcherQueue.TryEnqueue(() => Render(state));
    }

    private async Task RefreshAsync()
    {
        try
        {
            Render(await App.Current.Client.GetStateAsync());
        }
        catch (DaemonClient.OfflineException)
        {
            Render(null);
        }
        catch (Exception ex)
        {
            ErrorText.Text = ex.Message;
        }
    }

    private void Render(DaemonState? state)
    {
        _state = state;
        if (state is null)
        {
            StatusText.Text = App.Current.Host.IsInstalled ? "Daemon offline" : "Daemon not installed";
            DetailText.Text = App.Current.Host.IsInstalled
                ? "The bundled daemon is not responding. Start it to bring the proxy up."
                : "No daemon bundle found next to the app (bin\\droidproxy.exe).";
            StartStopButton.Content = "Start Server";
            StartStopButton.IsEnabled = App.Current.Host.IsInstalled;
            ProviderList.ItemsSource = Array.Empty<string>();
            ErrorText.Text = "";
            return;
        }

        StatusText.Text = state.ServerStarting ? "Starting…" : state.ServerRunning ? "Running" : "Stopped";
        DetailText.Text = state.ServerRunning
            ? $"Proxy on port {state.ProxyPort} · daemon {state.Version}"
            : $"Daemon {state.Version} is up; the proxy server is stopped.";
        StartStopButton.Content = state.ServerRunning ? "Stop Server" : "Start Server";
        StartStopButton.IsEnabled = true;
        ErrorText.Text = state.LastError;
        ProviderList.ItemsSource = state.Providers
            .Select(p => $"{p.Name} — {(p.Enabled ? "on" : "off")}, {p.AccountCount} account(s)")
            .ToList();
    }

    private async void OnStartStopClicked(object sender, RoutedEventArgs e)
    {
        if (_state is null)
        {
            App.Current.Host.Start();
            await Task.Delay(500);
            await RefreshAsync();
            return;
        }
        try
        {
            var result = await App.Current.Client.CallAsync("server.toggle");
            if (!result.Ok) ErrorText.Text = result.Error;
        }
        catch (DaemonClient.OfflineException)
        {
            App.Current.Host.Start();
        }
        await RefreshAsync();
    }

    private async void OnRefreshClicked(object sender, RoutedEventArgs e) => await RefreshAsync();
}
