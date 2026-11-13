using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace DroidProxy.Daemon;

/// <summary>
/// Talks to the Go daemon's control API: HTTP/1.1 over a Unix socket.
/// GET /v1/state returns a full snapshot, POST /v1/call/&lt;method&gt; runs an
/// action, GET /v1/events streams NDJSON state/message events. The contract
/// is docs/control-api.md in the Omarchy repo; this client only consumes it.
/// </summary>
public sealed class DaemonClient : IDisposable
{
    private readonly HttpClient _http;

    public DaemonClient(string socketPath)
    {
        var handler = new SocketsHttpHandler
        {
            ConnectCallback = async (context, cancellationToken) =>
            {
                var socket = new Socket(AddressFamily.Unix, SocketType.Stream, ProtocolType.Unspecified);
                try
                {
                    await socket.ConnectAsync(new UnixDomainSocketEndPoint(socketPath), cancellationToken);
                    return new NetworkStream(socket, ownsSocket: true);
                }
                catch
                {
                    socket.Dispose();
                    throw;
                }
            },
        };
        _http = new HttpClient(handler) { BaseAddress = new Uri("http://droidproxy") };
    }

    public sealed class OfflineException : Exception
    {
        public OfflineException(Exception inner) : base("daemon is not running", inner) { }
    }

    private static bool IsOffline(Exception ex) =>
        ex is HttpRequestException or SocketException or IOException;

    public async Task<DaemonState> GetStateAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            using var resp = await _http.GetAsync("/v1/state", cancellationToken);
            resp.EnsureSuccessStatusCode();
            var json = await resp.Content.ReadAsStringAsync(cancellationToken);
            return DaemonState.Parse(json);
        }
        catch (Exception ex) when (IsOffline(ex))
        {
            throw new OfflineException(ex);
        }
    }

    public async Task<(bool Ok, string Message, string Error)> CallAsync(
        string method, object? parameters = null, CancellationToken cancellationToken = default)
    {
        try
        {
            var body = parameters is null ? "{}" : JsonSerializer.Serialize(parameters);
            using var content = new StringContent(body, Encoding.UTF8, "application/json");
            using var resp = await _http.PostAsync("/v1/call/" + Uri.EscapeDataString(method), content, cancellationToken);
            var json = await resp.Content.ReadAsStringAsync(cancellationToken);
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            return (
                root.TryGetProperty("ok", out var ok) && ok.ValueKind == JsonValueKind.True,
                root.TryGetProperty("message", out var m) ? m.GetString() ?? "" : "",
                root.TryGetProperty("error", out var e) ? e.GetString() ?? "" : "");
        }
        catch (Exception ex) when (IsOffline(ex))
        {
            throw new OfflineException(ex);
        }
    }

    /// <summary>
    /// Streams state snapshots until cancelled or the daemon drops the
    /// connection. Reconnecting is the caller's job.
    /// </summary>
    public async Task WatchAsync(Func<DaemonState, Task> onState, CancellationToken cancellationToken)
    {
        try
        {
            using var resp = await _http.GetAsync(
                "/v1/events", HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            resp.EnsureSuccessStatusCode();
            using var stream = await resp.Content.ReadAsStreamAsync(cancellationToken);
            using var reader = new StreamReader(stream);
            while (await reader.ReadLineAsync(cancellationToken) is { } line)
            {
                if (line.Length == 0) continue;
                using var doc = JsonDocument.Parse(line);
                if (doc.RootElement.TryGetProperty("type", out var type) &&
                    type.GetString() == "state" &&
                    doc.RootElement.TryGetProperty("state", out var state))
                {
                    await onState(DaemonState.Parse(state.GetRawText()));
                }
            }
        }
        catch (Exception ex) when (IsOffline(ex) && !cancellationToken.IsCancellationRequested)
        {
            throw new OfflineException(ex);
        }
    }

    public void Dispose() => _http.Dispose();
}

/// <summary>The daemon snapshot as rendered by this app.</summary>
public sealed record DaemonState(
    bool ServerRunning,
    bool ServerStarting,
    int ProxyPort,
    string ServerUrl,
    string DashboardUrl,
    string LastError,
    DaemonState.AppInfo App,
    bool FactoryInstalled,
    string AuthDir,
    string LogsDir,
    IReadOnlyList<DaemonState.ProviderInfo> Providers,
    IReadOnlyList<DaemonState.UsageInfo> Usage,
    DaemonState.SettingsInfo Settings)
{
    public sealed record AppInfo(string Version, string CliProxyApiVersion, string IssuesUrl);

    /// <summary>DeviceCode and DeviceUrl carry a pending device-code sign-in (Grok, Meta).</summary>
    public sealed record ProviderInfo(
        string Id, string Name, string Icon, string Color, string Kind,
        bool Enabled, bool PrimerApplies, bool Authenticating, string DeviceCode, string DeviceUrl,
        IReadOnlyList<AccountInfo> Accounts, IReadOnlyList<ModelInfo> Models);

    public sealed record AccountInfo(string Id, string DisplayName, bool Expired, bool Disabled);

    public sealed record ModelInfo(string Slug, string DisplayName, bool Enabled, bool Installed);

    public sealed record UsageInfo(
        string Id, string Provider, string ProviderName, string Email, bool Loading, string Error,
        IReadOnlyList<WindowInfo> Windows, int ResetCount);

    public sealed record WindowInfo(string Title, double? RemainingPercent, string ResetText);

    public sealed record SettingsInfo(IReadOnlyDictionary<string, bool> Flags, string SecretKey, string BindAddress);

    public static DaemonState Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var server = root.TryGetProperty("server", out var s) ? s : default;
        var app = root.TryGetProperty("app", out var a) ? a : default;
        var grok = root.TryGetProperty("grok", out var g) ? g : default;
        var meta = root.TryGetProperty("meta", out var mt) ? mt : default;
        var factory = root.TryGetProperty("factory", out var f) ? f : default;
        var paths = root.TryGetProperty("paths", out var pa) ? pa : default;

        var providers = new List<ProviderInfo>();
        if (root.TryGetProperty("providers", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var p in list.EnumerateArray())
            {
                var accounts = new List<AccountInfo>();
                if (p.TryGetProperty("accounts", out var acc) && acc.ValueKind == JsonValueKind.Array)
                {
                    foreach (var ac in acc.EnumerateArray())
                    {
                        accounts.Add(new AccountInfo(
                            GetString(ac, "id"), GetString(ac, "displayName"),
                            GetBool(ac, "expired"), GetBool(ac, "disabled")));
                    }
                }
                var models = new List<ModelInfo>();
                if (p.TryGetProperty("models", out var ms) && ms.ValueKind == JsonValueKind.Array)
                {
                    foreach (var m in ms.EnumerateArray())
                    {
                        models.Add(new ModelInfo(
                            GetString(m, "slug"), GetString(m, "displayName"),
                            GetBool(m, "enabled"), GetBool(m, "installed")));
                    }
                }
                var id = GetString(p, "id");
                var (code, url) = id switch
                {
                    "grok" => (GetString(grok, "userCode"), GetString(grok, "verificationUrl")),
                    "meta" => (GetString(meta, "deviceCode"), GetString(meta, "verificationUrl")),
                    _ => ("", ""),
                };
                providers.Add(new ProviderInfo(
                    id, GetString(p, "name"), GetString(p, "icon"), GetString(p, "color"), GetString(p, "kind"),
                    GetBool(p, "enabled"), GetBool(p, "primerApplies"), GetBool(p, "authenticating"), code, url,
                    accounts, models));
            }
        }

        var usage = new List<UsageInfo>();
        if (root.TryGetProperty("usage", out var usg) &&
            usg.TryGetProperty("accounts", out var uaccts) && uaccts.ValueKind == JsonValueKind.Array)
        {
            foreach (var ua in uaccts.EnumerateArray())
            {
                var windows = new List<WindowInfo>();
                if (ua.TryGetProperty("windows", out var ws) && ws.ValueKind == JsonValueKind.Array)
                {
                    foreach (var w in ws.EnumerateArray())
                    {
                        double? remaining = w.TryGetProperty("remainingPercent", out var r) &&
                            r.ValueKind == JsonValueKind.Number ? r.GetDouble() : null;
                        windows.Add(new WindowInfo(GetString(w, "title"), remaining, GetString(w, "resetText")));
                    }
                }
                var resetCount = ua.TryGetProperty("resetCredits", out var rc) ? GetInt(rc, "availableCount") : 0;
                usage.Add(new UsageInfo(
                    GetString(ua, "id"), GetString(ua, "provider"), GetString(ua, "providerName"),
                    GetString(ua, "email"), GetBool(ua, "loading"), GetString(ua, "error"),
                    windows, resetCount));
            }
        }

        var flags = new Dictionary<string, bool>();
        var secretKey = "";
        var bindAddress = "";
        if (root.TryGetProperty("settings", out var st) && st.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in st.EnumerateObject())
            {
                if (prop.Value.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    flags[prop.Name] = prop.Value.GetBoolean();
            }
            secretKey = GetString(st, "secretKey");
            bindAddress = GetString(st, "bindAddress");
        }

        return new DaemonState(
            GetBool(server, "running"), GetBool(server, "starting"), GetInt(server, "proxyPort"),
            GetString(server, "url"), GetString(server, "dashboardUrl"), GetString(server, "lastError"),
            new AppInfo(
                GetString(app, "version"), GetString(app, "cliProxyApiVersion"), GetString(app, "issuesUrl")),
            GetBool(factory, "modelsInstalled"),
            GetString(paths, "authDir"), GetString(paths, "logsDir"),
            providers, usage,
            new SettingsInfo(flags, secretKey, bindAddress));
    }

    private static string GetString(JsonElement el, string name) =>
        el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";

    private static bool GetBool(JsonElement el, string name) =>
        el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v) &&
        (v.ValueKind == JsonValueKind.True);

    private static int GetInt(JsonElement el, string name) =>
        el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v) && v.TryGetInt32(out var n) ? n : 0;
}
