using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using DroidProxy.Daemon;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.ApplicationModel.DataTransfer;
using Windows.UI;

namespace DroidProxy;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void Raise(string name) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string name = "")
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }
}

public interface IKeyed
{
    string Key { get; }
}

public static class KeyedSync
{
    /// <summary>
    /// Makes items match infos by key: existing view models are moved and
    /// updated in place, so their bound controls survive every snapshot.
    /// </summary>
    public static void SyncKeyed<TVm, TInfo>(
        this ObservableCollection<TVm> items, IEnumerable<TInfo> infos,
        Func<TInfo, string> keyOf, Func<TInfo, TVm> create, Action<TVm, TInfo> update) where TVm : IKeyed
    {
        var i = 0;
        foreach (var info in infos)
        {
            var key = keyOf(info);
            var j = i;
            while (j < items.Count && items[j].Key != key) j++;
            if (j == items.Count) items.Insert(i, create(info));
            else if (j != i) items.Move(j, i);
            update(items[i], info);
            i++;
        }
        while (items.Count > i) items.RemoveAt(items.Count - 1);
    }
}

/// <summary>
/// A switch whose truth lives in the daemon. Sync applies a snapshot without
/// echoing it back; a user flip commits, and snapshots are ignored until the
/// commit lands so a stale one can't bounce the switch.
/// </summary>
public sealed class Toggle(string key, string label, Func<bool, Task> commit) : Observable, IKeyed
{
    private bool _isOn;
    private int _inFlight;

    public string Key { get; } = key;
    public string Label { get; } = label;

    public bool IsOn
    {
        get => _isOn;
        set
        {
            if (Set(ref _isOn, value)) _ = CommitAsync(value);
        }
    }

    public void Sync(bool on)
    {
        if (_inFlight > 0 || _isOn == on) return;
        _isOn = on;
        Raise(nameof(IsOn));
    }

    private async Task CommitAsync(bool on)
    {
        _inFlight++;
        try { await commit(on); }
        finally { _inFlight--; }
    }
}

public enum ServerStatus { NotInstalled, Offline, Stopped, Starting, Running }

public sealed class AppViewModel : Observable
{
    private readonly DaemonHost _host;
    private readonly DaemonClient _client;
    private string _daemonSecretKey = "";
    private string _daemonBindAddress = "";
    private string _daemonError = "";

    public AppViewModel(DaemonHost host, DaemonClient client)
    {
        _host = host;
        _client = client;
        Toggle Flag(string key, string label) => new(key, label, on => CallAsync("settings.set", new { key, value = on }));
        AllowRemote = Flag("allowRemote", "Allow remote access");
        VerboseLogging = Flag("verboseLogging", "Verbose logging");
        SequentialFailover = Flag("sequentialAccountFailover", "Sequential account failover");
        RequestJournal = Flag("requestJournal", "Request journal");
        Beta = Flag("beta", "Beta features");
        LaunchAtLogin = new("launchAtLogin", "Launch at login", on =>
        {
            App.SetLaunchAtLogin(on);
            return Task.CompletedTask;
        });
        LaunchAtLogin.Sync(App.IsLaunchAtLoginEnabled());
    }

    public ObservableCollection<ProviderViewModel> Providers { get; } = [];
    public ObservableCollection<UsageViewModel> Usage { get; } = [];

    public Toggle AllowRemote { get; }
    public Toggle VerboseLogging { get; }
    public Toggle SequentialFailover { get; }
    public Toggle RequestJournal { get; }
    public Toggle Beta { get; }
    public Toggle LaunchAtLogin { get; }

    public ServerStatus Status
    {
        get;
        private set
        {
            if (!Set(ref field, value)) return;
            Raise(nameof(IsRunning));
            Raise(nameof(IsOnline));
            Raise(nameof(CanStartStop));
            Raise(nameof(StartStopLabel));
            Raise(nameof(StatusBrush));
        }
    }

    public bool IsRunning => Status == ServerStatus.Running;
    public bool IsOnline => Status is ServerStatus.Running or ServerStatus.Stopped or ServerStatus.Starting;
    public bool CanStartStop => Status != ServerStatus.NotInstalled;
    public string StartStopLabel => IsRunning ? "Stop server" : "Start server";

    public SolidColorBrush StatusBrush => new(Status switch
    {
        ServerStatus.Running => Color.FromArgb(255, 0x6C, 0xCB, 0x5F),
        ServerStatus.Starting => Color.FromArgb(255, 0xFC, 0xE1, 0x00),
        _ => Color.FromArgb(255, 0xFF, 0x99, 0xA4),
    });

    public string StatusText { get; private set => Set(ref field, value); } = "";
    public string StatusDetail { get; private set => Set(ref field, value); } = "";
    public int Port { get; private set => Set(ref field, value); }
    public string Url { get; private set => Set(ref field, value); } = "";
    public string DashboardUrl { get; private set => Set(ref field, value); } = "";
    public string Version { get; private set => Set(ref field, value); } = "";
    public string CliProxyApiVersion { get; private set => Set(ref field, value); } = "";
    public string IssuesUrl { get; private set => Set(ref field, value); } = "";
    public string AuthDir { get; private set => Set(ref field, value); } = "";
    public string LogsDir { get; private set => Set(ref field, value); } = "";

    public bool FactoryInstalled
    {
        get;
        private set
        {
            if (!Set(ref field, value)) return;
            Raise(nameof(FactoryDetail));
            Raise(nameof(FactoryAction));
        }
    }

    public string FactoryDetail => FactoryInstalled
        ? "Applied. Factory sees every enabled DroidProxy model."
        : "Factory can't see DroidProxy models until you apply them. Your Factory settings are backed up first.";

    public string FactoryAction => FactoryInstalled ? "Re-apply" : "Apply";

    public bool RemoteWithoutKey { get; private set => Set(ref field, value); }

    /// <summary>Edited text; only a changed daemon value overwrites it, so typing survives snapshots.</summary>
    public string SecretKeyDraft { get; set => Set(ref field, value); } = "";
    public string BindAddressDraft { get; set => Set(ref field, value); } = "";

    public string Message
    {
        get;
        set
        {
            if (Set(ref field, value)) Raise(nameof(HasMessage));
        }
    } = "";

    public bool HasMessage => Message.Length > 0;
    public InfoBarSeverity MessageSeverity { get; private set => Set(ref field, value); }

    public void ClearMessage() => Message = "";

    private void ShowError(string message)
    {
        MessageSeverity = InfoBarSeverity.Error;
        Message = message;
    }

    private void ShowSuccess(string message)
    {
        MessageSeverity = InfoBarSeverity.Success;
        Message = message;
    }

    public void Apply(DaemonState? s)
    {
        if (s is null)
        {
            Status = _host.IsInstalled || _host.IsExternal ? ServerStatus.Offline : ServerStatus.NotInstalled;
            (StatusText, StatusDetail) = Status == ServerStatus.Offline
                ? ("Daemon offline", "The bundled daemon is not responding. Start it to bring the proxy up.")
                : ("Daemon not installed", "No daemon bundle found next to the app (daemon\\bin\\droidproxy.exe).");
            Providers.Clear();
            Usage.Clear();
            return;
        }
        Port = s.ProxyPort;
        Version = s.App.Version;
        Status = s.ServerStarting ? ServerStatus.Starting : s.ServerRunning ? ServerStatus.Running : ServerStatus.Stopped;
        (StatusText, StatusDetail) = Status switch
        {
            ServerStatus.Running => ($"Running on :{s.ProxyPort}", $"Proxy on port {s.ProxyPort}, daemon {Version}"),
            ServerStatus.Starting => ("Starting…", "The proxy server is starting."),
            _ => ("Stopped", $"Daemon {Version} is up; the proxy server is stopped."),
        };
        Url = s.ServerUrl;
        DashboardUrl = s.DashboardUrl;
        CliProxyApiVersion = s.App.CliProxyApiVersion;
        IssuesUrl = s.App.IssuesUrl;
        AuthDir = s.AuthDir;
        LogsDir = s.LogsDir;
        FactoryInstalled = s.FactoryInstalled;
        if (_daemonError != s.LastError)
        {
            _daemonError = s.LastError;
            if (_daemonError.Length > 0) ShowError(_daemonError);
        }

        var flags = s.Settings.Flags;
        foreach (var t in new[] { AllowRemote, VerboseLogging, SequentialFailover, RequestJournal, Beta })
            t.Sync(flags.GetValueOrDefault(t.Key));
        if (_daemonSecretKey != s.Settings.SecretKey) SecretKeyDraft = _daemonSecretKey = s.Settings.SecretKey;
        if (_daemonBindAddress != s.Settings.BindAddress) BindAddressDraft = _daemonBindAddress = s.Settings.BindAddress;
        RemoteWithoutKey = AllowRemote.IsOn && s.Settings.SecretKey.Length == 0;

        Providers.SyncKeyed(s.Providers, p => p.Id, p => new ProviderViewModel(this, p.Id), (vm, p) => vm.Sync(p, s));
        var colors = s.Providers.ToDictionary(p => p.Id, p => p.Color);
        Usage.SyncKeyed(s.Usage, u => $"{u.Provider}/{u.Id}", u => new UsageViewModel(this, u),
            (vm, u) => vm.Sync(u, colors.GetValueOrDefault(u.Provider, "")));
    }

    public async Task RefreshAsync()
    {
        try
        {
            Apply(await _client.GetStateAsync());
        }
        catch (DaemonClient.OfflineException)
        {
            Apply(null);
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
    }

    public async Task CallAsync(string method, object? parameters = null)
    {
        try
        {
            var result = await _client.CallAsync(method, parameters);
            if (result.Ok) ClearMessage();
            else ShowError(result.Error);
        }
        catch (DaemonClient.OfflineException)
        {
            ShowError("Daemon is not running.");
        }
        catch (Exception ex)
        {
            ShowError(ex.Message);
        }
        await RefreshAsync();
    }

    public async void StartStop()
    {
        if (!IsOnline)
        {
            _host.Start();
            await Task.Delay(600);
            await RefreshAsync();
            return;
        }
        await CallAsync("server.toggle");
    }

    public async void RefreshUsage() => await CallAsync("usage.refresh");
    public async void ApplyFactory() => await CallAsync("factory.apply");
    public async void SaveSecretKey() => await CallAsync("settings.set", new { key = "secretKey", value = SecretKeyDraft });
    public async void SaveBindAddress() => await CallAsync("settings.set", new { key = "bindAddress", value = BindAddressDraft });

    public void CopyUrl() => Copy(Url, "Server URL copied.");
    public void OpenDashboard() => Open(DashboardUrl);
    public void ReportIssue() => Open(IssuesUrl);
    public void OpenAuthFolder() => OpenFolder(AuthDir);
    public void OpenLogsFolder() => OpenFolder(LogsDir);

    public void Copy(string text, string confirmation)
    {
        if (text.Length == 0) return;
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        ShowSuccess(confirmation);
    }

    public static async void Open(string url)
    {
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri)) await Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private static void OpenFolder(string path)
    {
        if (path.Length == 0) return;
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    internal static Color ParseColor(string hex) =>
        hex.Length == 7 && hex[0] == '#' && uint.TryParse(hex.AsSpan(1), System.Globalization.NumberStyles.HexNumber, null, out var rgb)
            ? Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb)
            : Color.FromArgb(255, 0xF2, 0x7D, 0x30);
}

public sealed class ProviderViewModel : Observable, IKeyed
{
    // Provider-specific settings flags, beyond the per-model toggles.
    private static readonly Dictionary<string, (string Key, string Label)[]> Extras = new()
    {
        ["codex"] =
        [
            ("gpt6AstraFastMode", "GPT 6 Astra fast mode"),
            ("gpt61SolFastMode", "GPT 6.1 Sol fast mode"),
            ("gpt61TerraFastMode", "GPT 6.1 Terra fast mode"),
            ("gpt6LunaFastMode", "GPT 6 Luna fast mode"),
        ],
        ["meta"] = [("metaContributorMode", "Contributor mode")],
    };

    private readonly AppViewModel _app;
    private string _iconName = "";

    public ProviderViewModel(AppViewModel app, string id)
    {
        _app = app;
        Key = id;
        Enabled = new("enabled", "", on => app.CallAsync("provider.setEnabled", new { provider = id, enabled = on }));
    }

    public string Key { get; }
    public Toggle Enabled { get; }
    public ObservableCollection<AccountViewModel> Accounts { get; } = [];
    public ObservableCollection<Toggle> Models { get; } = [];
    public ObservableCollection<Toggle> Options { get; } = [];

    public string Name { get; private set => Set(ref field, value); } = "";
    public string Summary { get; private set => Set(ref field, value); } = "";
    public ImageSource? Icon { get; private set => Set(ref field, value); }
    public bool HasIcon { get; private set => Set(ref field, value); }
    public bool HasInitial { get; private set => Set(ref field, value); }
    public string Initial { get; private set => Set(ref field, value); } = "";
    public SolidColorBrush Brush { get; private set => Set(ref field, value); } = new();
    public SolidColorBrush TileBrush { get; private set => Set(ref field, value); } = new();
    public bool IsJunie { get; private set => Set(ref field, value); }
    public bool HasModels { get; private set => Set(ref field, value); }
    public bool HasOptions { get; private set => Set(ref field, value); }
    public string ActionLabel { get; private set => Set(ref field, value); } = "";
    public bool HasAction { get; private set => Set(ref field, value); }
    public bool Authenticating { get; private set => Set(ref field, value); }
    public string DeviceCode { get; private set => Set(ref field, value); } = "";
    public string DeviceUrl { get; private set => Set(ref field, value); } = "";
    public bool HasDeviceCode { get; private set => Set(ref field, value); }
    public string ApiKeyDraft { get; set => Set(ref field, value); } = "";

    internal void Sync(DaemonState.ProviderInfo p, DaemonState s)
    {
        Name = p.Name;
        Initial = p.Name.Length > 0 ? p.Name[..1] : "?";
        if (_iconName != p.Icon)
        {
            // The daemon sends a file name from the Mac app's resources; the Windows copies ship in Assets\Providers.
            _iconName = p.Icon;
            var bundled = p.Icon.Length > 0 && File.Exists(Path.Combine(AppContext.BaseDirectory, "Assets", "Providers", p.Icon));
            var uri = new Uri($"ms-appx:///Assets/Providers/{p.Icon}");
            Icon = !bundled ? null
                : p.Icon.EndsWith(".svg", StringComparison.OrdinalIgnoreCase) ? new SvgImageSource(uri)
                : new BitmapImage(uri);
            HasIcon = Icon is not null;
            HasInitial = !HasIcon;
        }
        var color = AppViewModel.ParseColor(p.Color);
        if (Brush.Color != color)
        {
            Brush = new SolidColorBrush(color);
            TileBrush = new SolidColorBrush(Color.FromArgb(0x40, color.R, color.G, color.B));
        }
        IsJunie = p.Kind == "junie";
        Authenticating = p.Authenticating;
        HasAction = !IsJunie;
        ActionLabel = p.Authenticating ? "Cancel sign-in" : p.Kind is "grok" or "meta" ? "Sign in" : "Add account";
        DeviceCode = p.DeviceCode;
        DeviceUrl = p.DeviceUrl;
        HasDeviceCode = p.DeviceCode.Length > 0;
        Enabled.Sync(p.Enabled);

        var usage = s.Usage.Where(u => u.Provider == p.Id).ToDictionary(u => u.Id, u => u);
        Accounts.SyncKeyed(p.Accounts, a => a.Id, a => new AccountViewModel(_app, p.Id, a.Id),
            (vm, a) => vm.Sync(a, usage.GetValueOrDefault(a.Id)));

        Models.SyncKeyed(p.Models, m => m.Slug, m => new Toggle(m.Slug, m.DisplayName, async on =>
        {
            await _app.CallAsync("model.setEnabled", new { slug = m.Slug, enabled = on });
            await _app.CallAsync("factory.apply");
        }), (t, m) => t.Sync(m.Enabled));
        HasModels = Models.Count > 0;

        var options = Extras.GetValueOrDefault(p.Id, []).AsEnumerable();
        if (p.PrimerApplies && p.Id is "claude" or "codex" or "meta")
            options = options.Prepend(($"windowPrimerEnabled.{p.Id}", "Auto-start daily (5-hour window)"));
        Options.SyncKeyed(options, o => o.Key,
            o => new Toggle(o.Key, o.Label, on => _app.CallAsync("settings.set", new { key = o.Key, value = on })),
            (t, _) => t.Sync(s.Settings.Flags.GetValueOrDefault(t.Key)));
        HasOptions = Options.Count > 0;

        var accounts = p.Accounts.Count switch
        {
            0 when IsJunie => "Needs a JetBrains API key",
            0 => "No account connected",
            1 => "1 account",
            var n => $"{n} accounts",
        };
        var inFactory = p.Models.Count(m => m.Enabled && m.Installed);
        Summary = p.Models.Count > 0 ? $"{accounts} · {inFactory} of {p.Models.Count} models in Factory" : accounts;
    }

    public async void Act() =>
        await _app.CallAsync(Authenticating ? "provider.cancelAuth" : "provider.connect", new { provider = Key });

    public async void SaveKey() => await _app.CallAsync("junie.saveKey", new { apiKey = ApiKeyDraft });
    public void CopyCode() => _app.Copy(DeviceCode, "Sign-in code copied.");
    public void OpenSignIn() => AppViewModel.Open(DeviceUrl);
}

public sealed class AccountViewModel : Observable, IKeyed
{
    private readonly AppViewModel _app;
    private readonly string _provider;

    public AccountViewModel(AppViewModel app, string provider, string id)
    {
        _app = app;
        _provider = provider;
        Key = id;
        Enabled = new("enabled", "", _ => app.CallAsync("account.toggleDisabled", new { provider, accountId = id }));
    }

    public string Key { get; }
    public Toggle Enabled { get; }
    public string Name { get; private set => Set(ref field, value); } = "";
    public string Detail { get; private set => Set(ref field, value); } = "";

    internal void Sync(DaemonState.AccountInfo a, DaemonState.UsageInfo? usage)
    {
        Name = a.DisplayName;
        Enabled.Sync(!a.Disabled);
        Detail = a.Expired ? "Expired · sign in again"
            : a.Disabled ? "Disabled"
            : usage is { Error.Length: > 0 } ? usage.Error
            : usage?.Windows.FirstOrDefault(w => w.RemainingPercent is not null) is { } w
                ? $"{w.Title} · {w.RemainingPercent:0}% left · resets {w.ResetText}"
                : "";
    }

    public async void Remove()
    {
        if (await App.Current.ConfirmAsync($"Remove {Name}?",
                "The account's credential file will be deleted from this machine.", "Remove"))
            await _app.CallAsync("account.remove", new { provider = _provider, accountId = Key });
    }
}

public sealed class UsageViewModel(AppViewModel app, DaemonState.UsageInfo info) : Observable, IKeyed
{
    public string Key { get; } = $"{info.Provider}/{info.Id}";
    public ObservableCollection<QuotaWindow> Windows { get; } = [];
    public string ProviderName { get; private set => Set(ref field, value); } = "";
    public string Email { get; private set => Set(ref field, value); } = "";
    public bool Loading { get; private set => Set(ref field, value); }
    public string Error { get; private set => Set(ref field, value); } = "";
    public bool HasError { get; private set => Set(ref field, value); }
    public string ResetLabel { get; private set => Set(ref field, value); } = "";
    public bool HasResets { get; private set => Set(ref field, value); }

    internal void Sync(DaemonState.UsageInfo u, string color)
    {
        ProviderName = u.ProviderName;
        Email = u.Email;
        Loading = u.Loading;
        Error = u.Error;
        HasError = u.Error.Length > 0;
        HasResets = u.ResetCount > 0;
        ResetLabel = u.ResetCount == 1 ? "1 banked reset" : $"{u.ResetCount} banked resets";
        var brush = AppViewModel.ParseColor(color);
        Windows.SyncKeyed(u.Windows, w => w.Title, w => new QuotaWindow(w.Title), (vm, w) => vm.Sync(w, brush));
    }

    public async void UseReset()
    {
        if (await App.Current.ConfirmAsync("Use a banked reset?",
                $"Spend one banked reset for {Email}? This cannot be undone.", "Use reset"))
            await app.CallAsync("usage.redeemReset", new { provider = info.Provider, accountId = info.Id });
    }
}

public sealed class QuotaWindow(string title) : Observable, IKeyed
{
    public string Key { get; } = title;
    public string Title { get; } = title;
    public double Percent { get; private set => Set(ref field, value); }
    public string PercentText { get; private set => Set(ref field, value); } = "";
    public string ResetText { get; private set => Set(ref field, value); } = "";
    public SolidColorBrush Brush { get; private set => Set(ref field, value); } = new();

    internal void Sync(DaemonState.WindowInfo w, Color color)
    {
        Percent = w.RemainingPercent ?? 0;
        PercentText = w.RemainingPercent is { } r ? $"{r:0}%" : "–";
        ResetText = w.ResetText.Length > 0 ? $"Resets {w.ResetText}" : "";
        if (Brush.Color != color) Brush = new SolidColorBrush(color);
    }
}
