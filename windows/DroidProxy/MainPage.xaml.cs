using System.Diagnostics;
using DroidProxy.Daemon;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace DroidProxy;

/// <summary>
/// Renders the daemon snapshot: server state, quota usage with banked
/// resets, providers with accounts and per-model Factory toggles, and the
/// daemon settings. Every action goes through the control API, the same
/// contract the Omarchy panel uses.
/// </summary>
public sealed partial class MainPage : Page
{
    private DaemonState? _state;
    private bool _rendering;

    public MainPage()
    {
        InitializeComponent();
        Loaded += OnLoaded;
        Unloaded += OnUnloaded;
    }

    private DaemonClient Client => App.Current.Client;

    private void OnLoaded(object sender, RoutedEventArgs e)
    {
        App.Current.StateChanged += OnStateChanged;
        _ = RefreshAsync();
    }

    private void OnUnloaded(object sender, RoutedEventArgs e) => App.Current.StateChanged -= OnStateChanged;

    private void OnStateChanged(DaemonState? state) => DispatcherQueue.TryEnqueue(() => Render(state));

    private async Task RefreshAsync()
    {
        try
        {
            Render(await Client.GetStateAsync());
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

    private async Task CallAsync(string method, object? parameters = null)
    {
        try
        {
            var result = await Client.CallAsync(method, parameters);
            ErrorText.Text = result.Ok ? "" : result.Error;
        }
        catch (DaemonClient.OfflineException)
        {
            ErrorText.Text = "Daemon is not running.";
        }
        catch (Exception ex)
        {
            ErrorText.Text = ex.Message;
        }
        await RefreshAsync();
    }

    private void Render(DaemonState? state)
    {
        _state = state;
        _rendering = true;
        try
        {
            RenderHeader(state);
            RenderUpdate(state);
            RenderSignIn(state);
            RenderFactory(state);
            RenderUsage(state);
            RenderProviders(state);
            RenderSettings(state);
        }
        finally
        {
            _rendering = false;
        }
    }

    private void RenderHeader(DaemonState? state)
    {
        if (state is null)
        {
            StatusText.Text = App.Current.Host.IsInstalled ? "Daemon offline" : "Daemon not installed";
            DetailText.Text = App.Current.Host.IsInstalled
                ? "The bundled daemon is not responding. Start it to bring the proxy up."
                : "No daemon bundle found next to the app (daemon\\bin\\droidproxy.exe).";
            StartStopButton.Content = "Start Server";
            StartStopButton.IsEnabled = App.Current.Host.IsInstalled;
            return;
        }
        StatusText.Text = state.ServerStarting ? "Starting…" : state.ServerRunning ? "Running" : "Stopped";
        DetailText.Text = state.ServerRunning
            ? $"Proxy on port {state.ProxyPort} · daemon {state.Version}"
            : $"Daemon {state.Version} is up; the proxy server is stopped.";
        StartStopButton.Content = state.ServerRunning ? "Stop Server" : "Start Server";
        StartStopButton.IsEnabled = true;
        if (state.LastError.Length > 0) ErrorText.Text = state.LastError;
    }

    private void RenderUpdate(DaemonState? state)
    {
        UpdatePanel.Children.Clear();
        if (state is not { UpdateState: "available" }) return;
        UpdatePanel.Children.Add(new TextBlock
        {
            Text = $"Version {state.LatestVersion} is ready",
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        var install = new Button { Content = "Install update" };
        install.Click += async (_, _) => await CallAsync("update.install");
        UpdatePanel.Children.Add(install);
    }

    private void RenderSignIn(DaemonState? state)
    {
        SignInPanel.Children.Clear();
        if (state is null) return;
        void AddCode(string label, string code, string url)
        {
            if (code.Length == 0) return;
            SignInPanel.Children.Add(new TextBlock { Text = $"{label} sign-in code: {code}", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            if (url.Length > 0)
            {
                var link = new HyperlinkButton { Content = url };
                link.Click += async (_, _) => await Windows.System.Launcher.LaunchUriAsync(new Uri(url));
                SignInPanel.Children.Add(link);
            }
        }
        AddCode("Grok", state.SignIn.GrokCode, state.SignIn.GrokUrl);
        AddCode("Meta", state.SignIn.MetaCode, state.SignIn.MetaUrl);
        AddCode("Copilot", state.SignIn.CopilotCode, state.SignIn.CopilotUrl);
    }

    private void RenderFactory(DaemonState? state)
    {
        FactoryPanel.Children.Clear();
        if (state is null || state.FactoryInstalled) return;
        FactoryPanel.Children.Add(new TextBlock
        {
            Text = "Factory can't see DroidProxy models until you apply them.",
            TextWrapping = TextWrapping.WrapWholeWords,
        });
        var apply = new Button { Content = "Apply Factory Models" };
        apply.Click += async (_, _) => await CallAsync("factory.apply");
        FactoryPanel.Children.Add(apply);
    }

    private void RenderUsage(DaemonState? state)
    {
        UsagePanel.Children.Clear();
        if (state is null || state.Usage.Count == 0)
        {
            UsagePanel.Children.Add(new TextBlock { Text = "No usage yet.", Opacity = 0.75 });
            return;
        }
        foreach (var account in state.Usage)
        {
            var block = new StackPanel { Spacing = 6 };
            block.Children.Add(new TextBlock
            {
                Text = $"{account.ProviderName} · {account.Email}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            });
            if (account.Loading)
            {
                block.Children.Add(new ProgressRing { IsActive = true, Width = 20, Height = 20 });
            }
            var rings = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
            foreach (var w in account.Windows)
            {
                var cell = new StackPanel { Spacing = 2, Width = 120 };
                var ringGrid = new Grid { Width = 56, Height = 56, HorizontalAlignment = HorizontalAlignment.Left };
                ringGrid.Children.Add(new ProgressRing
                {
                    IsIndeterminate = false,
                    Minimum = 0,
                    Maximum = 100,
                    Value = w.RemainingPercent ?? 0,
                    Width = 52,
                    Height = 52,
                });
                ringGrid.Children.Add(new TextBlock
                {
                    Text = w.RemainingPercent is { } r ? $"{Math.Round(r):0}" : "–",
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                    FontSize = 12,
                });
                cell.Children.Add(ringGrid);
                cell.Children.Add(new TextBlock { Text = w.Title, FontSize = 11, TextWrapping = TextWrapping.WrapWholeWords });
                if (w.ResetText.Length > 0)
                    cell.Children.Add(new TextBlock { Text = w.ResetText, FontSize = 11, Opacity = 0.7, TextWrapping = TextWrapping.WrapWholeWords });
                rings.Children.Add(cell);
            }
            if (account.Windows.Count > 0) block.Children.Add(rings);
            if (account.ResetCount > 0)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(new TextBlock
                {
                    Text = $"{account.ResetCount} banked reset(s) available",
                    VerticalAlignment = VerticalAlignment.Center,
                });
                var use = new Button { Content = "Use reset" };
                var captured = account;
                use.Click += async (_, _) => await ConfirmResetAsync(captured);
                row.Children.Add(use);
                block.Children.Add(row);
            }
            if (account.Error.Length > 0)
            {
                block.Children.Add(new TextBlock { Text = account.Error, Opacity = 0.75, TextWrapping = TextWrapping.WrapWholeWords });
            }
            UsagePanel.Children.Add(block);
        }
    }

    private async Task ConfirmResetAsync(DaemonState.UsageInfo account)
    {
        var dialog = new ContentDialog
        {
            Title = "Use a banked reset?",
            Content = $"Spend one banked reset for {account.Email}? This cannot be undone.",
            PrimaryButtonText = "Use reset",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await CallAsync("usage.redeemReset", new { provider = account.Provider, accountId = account.Id });
        }
    }

    private void RenderProviders(DaemonState? state)
    {
        ProvidersPanel.Children.Clear();
        if (state is null) return;

        foreach (var provider in state.Providers)
        {
            var captured = provider;
            var content = new StackPanel { Spacing = 6, Padding = new Thickness(0, 4, 0, 8) };

            foreach (var account in provider.Accounts)
            {
                var capturedAccount = account;
                var row = new Grid();
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var label = capturedAccount.DisplayName
                    + (capturedAccount.Expired ? " (expired)" : "")
                    + (capturedAccount.Disabled ? " (disabled)" : "");
                var name = new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center };
                Grid.SetColumn(name, 0);
                row.Children.Add(name);
                var toggle = new Button { Content = capturedAccount.Disabled ? "Enable" : "Disable", Margin = new Thickness(6, 0, 0, 0) };
                toggle.Click += async (_, _) => await CallAsync(
                    "account.toggleDisabled", new { provider = captured.Id, accountId = capturedAccount.Id });
                Grid.SetColumn(toggle, 1);
                row.Children.Add(toggle);
                var remove = new Button { Content = "Remove", Margin = new Thickness(6, 0, 0, 0) };
                remove.Click += async (_, _) => await ConfirmRemoveAsync(captured, capturedAccount);
                Grid.SetColumn(remove, 2);
                row.Children.Add(remove);
                content.Children.Add(row);
            }

            if (provider.Kind == "junie")
            {
                var keyBox = new PasswordBox { PlaceholderText = "JetBrains Junie API key" };
                var save = new Button { Content = "Save key", Margin = new Thickness(0, 4, 0, 0) };
                save.Click += async (_, _) => await CallAsync("junie.saveKey", new { apiKey = keyBox.Password });
                content.Children.Add(keyBox);
                content.Children.Add(save);
            }
            else if (provider.Authenticating)
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                row.Children.Add(new ProgressRing { IsActive = true, Width = 18, Height = 18 });
                row.Children.Add(new TextBlock { Text = "Signing in…", VerticalAlignment = VerticalAlignment.Center });
                var cancel = new Button { Content = "Cancel" };
                cancel.Click += async (_, _) => await CallAsync("provider.cancelAuth", new { provider = captured.Id });
                row.Children.Add(cancel);
                content.Children.Add(row);
            }
            else
            {
                var add = new Button { Content = "Add Account" };
                add.Click += async (_, _) => await CallAsync("provider.connect", new { provider = captured.Id });
                content.Children.Add(add);
            }

            if (provider.Models.Count > 0)
            {
                content.Children.Add(new TextBlock
                {
                    Text = "Factory models",
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    Margin = new Thickness(0, 6, 0, 0),
                });
                foreach (var model in provider.Models)
                {
                    var capturedModel = model;
                    var row = new Grid();
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                    row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                    var name = new StackPanel();
                    name.Children.Add(new TextBlock { Text = capturedModel.DisplayName });
                    if (capturedModel.Enabled && !capturedModel.Installed)
                    {
                        name.Children.Add(new TextBlock { Text = "Not in Factory", FontSize = 11, Opacity = 0.7 });
                    }
                    Grid.SetColumn(name, 0);
                    row.Children.Add(name);
                    var toggle = new ToggleSwitch { IsOn = capturedModel.Enabled, OnContent = "In Factory", OffContent = "Off" };
                    toggle.Toggled += async (_, _) =>
                    {
                        if (_rendering) return;
                        // The switch is the whole control: persist, then
                        // reconcile the Factory config immediately.
                        await CallAsync("model.setEnabled", new { slug = capturedModel.Slug, enabled = toggle.IsOn });
                        await CallAsync("factory.apply");
                    };
                    Grid.SetColumn(toggle, 1);
                    row.Children.Add(toggle);
                    content.Children.Add(row);
                }
            }

            if (provider.PrimerApplies && provider.Id is "claude" or "codex" or "meta")
            {
                var key = $"windowPrimerEnabled.{provider.Id}";
                var primer = new ToggleSwitch
                {
                    Header = "Auto-start daily (5-hour window)",
                    IsOn = state.Settings.Flags.GetValueOrDefault(key),
                };
                primer.Toggled += async (_, _) =>
                {
                    if (_rendering) return;
                    await CallAsync("settings.set", new { key, value = primer.IsOn });
                };
                content.Children.Add(primer);
            }

            if (provider.Id == "codex")
            {
                foreach (var (key, label) in new[]
                {
                    ("gpt6AstraFastMode", "GPT 6 Astra Fast Mode"),
                    ("gpt61SolFastMode", "GPT 6.1 Sol Fast Mode"),
                    ("gpt61TerraFastMode", "GPT 6.1 Terra Fast Mode"),
                    ("gpt6LunaFastMode", "GPT 6 Luna Fast Mode"),
                })
                {
                    var capturedKey = key;
                    var fast = new ToggleSwitch { Header = label, IsOn = state.Settings.Flags.GetValueOrDefault(key) };
                    fast.Toggled += async (_, _) =>
                    {
                        if (_rendering) return;
                        await CallAsync("settings.set", new { key = capturedKey, value = fast.IsOn });
                    };
                    content.Children.Add(fast);
                }
            }

            if (provider.Id == "meta")
            {
                var contributor = new ToggleSwitch
                {
                    Header = "Meta contributor mode",
                    IsOn = state.Settings.Flags.GetValueOrDefault("metaContributorMode"),
                };
                contributor.Toggled += async (_, _) =>
                {
                    if (_rendering) return;
                    await CallAsync("settings.set", new { key = "metaContributorMode", value = contributor.IsOn });
                };
                content.Children.Add(contributor);
            }

            var headerGrid = new Grid();
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            headerGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var title = new TextBlock
            {
                Text = $"{provider.Name}  ({provider.Accounts.Count} account(s))",
                VerticalAlignment = VerticalAlignment.Center,
            };
            Grid.SetColumn(title, 0);
            headerGrid.Children.Add(title);
            var providerToggle = new ToggleSwitch { IsOn = provider.Enabled, OnContent = "", OffContent = "" };
            providerToggle.Toggled += async (_, _) =>
            {
                if (_rendering) return;
                await CallAsync("provider.setEnabled", new { provider = captured.Id, enabled = providerToggle.IsOn });
            };
            Grid.SetColumn(providerToggle, 1);
            headerGrid.Children.Add(providerToggle);

            ProvidersPanel.Children.Add(new Expander
            {
                Header = headerGrid,
                Content = content,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch,
            });
        }
    }

    private async Task ConfirmRemoveAsync(DaemonState.ProviderInfo provider, DaemonState.AccountInfo account)
    {
        var dialog = new ContentDialog
        {
            Title = $"Remove {account.DisplayName}?",
            Content = "The account's credential file will be deleted from this machine.",
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
            XamlRoot = XamlRoot,
        };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary)
        {
            await CallAsync("account.remove", new { provider = provider.Id, accountId = account.Id });
        }
    }

    private void RenderSettings(DaemonState? state)
    {
        SettingsPanel.Children.Clear();
        if (state is null) return;
        var s = state.Settings;

        ToggleSwitch FlagToggle(string label, string key) => new()
        {
            Header = label,
            IsOn = s.Flags.GetValueOrDefault(key),
        };
        void Wire(ToggleSwitch toggle, string key) =>
            toggle.Toggled += async (_, _) =>
            {
                if (_rendering) return;
                await CallAsync("settings.set", new { key, value = toggle.IsOn });
            };

        var autostart = new ToggleSwitch { Header = "Launch at login", IsOn = App.IsLaunchAtLoginEnabled() };
        autostart.Toggled += (_, _) =>
        {
            if (_rendering) return;
            App.SetLaunchAtLogin(autostart.IsOn);
        };
        SettingsPanel.Children.Add(autostart);

        foreach (var (label, key) in new[]
        {
            ("Allow remote access", "allowRemote"),
            ("Verbose logging", "verboseLogging"),
            ("Sequential account failover", "sequentialAccountFailover"),
            ("Beta features", "beta"),
            ("Request journal", "requestJournal"),
        })
        {
            var t = FlagToggle(label, key);
            Wire(t, key);
            SettingsPanel.Children.Add(t);
        }

        if (s.Flags.GetValueOrDefault("beta"))
        {
            var bind = new TextBox { Header = "Bind address", Text = s.BindAddress };
            var saveBind = new Button { Content = "Save bind address" };
            saveBind.Click += async (_, _) => await CallAsync("settings.set", new { key = "bindAddress", value = bind.Text });
            SettingsPanel.Children.Add(bind);
            SettingsPanel.Children.Add(saveBind);
        }

        var secret = new PasswordBox { Header = "Remote management secret key", Password = s.SecretKey };
        var saveSecret = new Button { Content = "Save secret key" };
        saveSecret.Click += async (_, _) => await CallAsync("settings.set", new { key = "secretKey", value = secret.Password });
        SettingsPanel.Children.Add(secret);
        SettingsPanel.Children.Add(saveSecret);

        var folders = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var authButton = new Button { Content = "Open Auth Folder" };
        authButton.Click += (_, _) => OpenFolder(state.AuthDir);
        var logsButton = new Button { Content = "Open Logs Folder" };
        logsButton.Click += (_, _) => OpenFolder(state.LogsDir);
        folders.Children.Add(authButton);
        folders.Children.Add(logsButton);
        SettingsPanel.Children.Add(folders);
    }

    private static void OpenFolder(string path)
    {
        if (path.Length == 0) return;
        Directory.CreateDirectory(path);
        Process.Start(new ProcessStartInfo("explorer.exe", $"\"{path}\"") { UseShellExecute = true });
    }

    private async void OnStartStopClicked(object sender, RoutedEventArgs e)
    {
        if (_state is null)
        {
            App.Current.Host.Start();
            await Task.Delay(600);
            await RefreshAsync();
            return;
        }
        await CallAsync("server.toggle");
    }

    private async void OnRefreshClicked(object sender, RoutedEventArgs e)
    {
        await CallAsync("usage.refresh");
        await RefreshAsync();
    }
}
