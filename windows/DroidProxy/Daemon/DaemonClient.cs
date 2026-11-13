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
    /// Streams state snapshots and daemon messages until cancelled or the daemon drops the
    /// connection. Reconnecting is the caller's job.
    /// </summary>
    public async Task WatchAsync(
        Func<DaemonState, Task> onState, Action<string, bool> onMessage, CancellationToken cancellationToken)
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
                var root = doc.RootElement;
                switch (DaemonState.GetString(root, "type"))
                {
                    case "state" when root.TryGetProperty("state", out var state):
                        await onState(DaemonState.Parse(state.GetRawText()));
                        break;
                    case "message":
                        onMessage(DaemonState.GetString(root, "body"), DaemonState.GetString(root, "level") == "error");
                        break;
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
    public sealed record AppInfo(string Version, string CliProxyApiVersion);

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
        var server = Prop(root, "server");
        var app = Prop(root, "app");
        var grok = Prop(root, "grok");
        var meta = Prop(root, "meta");
        var paths = Prop(root, "paths");

        var providers = new List<ProviderInfo>();
        foreach (var p in Items(root, "providers"))
        {
            var accounts = Items(p, "accounts").Select(ac => new AccountInfo(
                GetString(ac, "id"), GetString(ac, "displayName"),
                GetBool(ac, "expired"), GetBool(ac, "disabled"))).ToList();
            var models = Items(p, "models").Select(m => new ModelInfo(
                GetString(m, "slug"), GetString(m, "displayName"),
                GetBool(m, "enabled"), GetBool(m, "installed"))).ToList();
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

        var usage = new List<UsageInfo>();
        foreach (var ua in Items(Prop(root, "usage"), "accounts"))
        {
            var windows = Items(ua, "windows").Select(w => new WindowInfo(
                GetString(w, "title"),
                Prop(w, "remainingPercent") is { ValueKind: JsonValueKind.Number } r ? r.GetDouble() : null,
                GetString(w, "resetText"))).ToList();
            usage.Add(new UsageInfo(
                GetString(ua, "id"), GetString(ua, "provider"), GetString(ua, "providerName"),
                GetString(ua, "email"), GetBool(ua, "loading"), GetString(ua, "error"),
                windows, GetInt(Prop(ua, "resetCredits"), "availableCount")));
        }

        var flags = new Dictionary<string, bool>();
        var settings = Prop(root, "settings");
        if (settings.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in settings.EnumerateObject())
            {
                if (prop.Value.ValueKind is JsonValueKind.True or JsonValueKind.False)
                    flags[prop.Name] = prop.Value.GetBoolean();
            }
        }

        return new DaemonState(
            GetBool(server, "running"), GetBool(server, "starting"), GetInt(server, "proxyPort"),
            GetString(server, "url"), GetString(server, "dashboardUrl"), GetString(server, "lastError"),
            new AppInfo(GetString(app, "version"), GetString(app, "cliProxyApiVersion")),
            GetBool(Prop(root, "factory"), "modelsInstalled"),
            GetString(paths, "authDir"), GetString(paths, "logsDir"),
            providers, usage,
            new SettingsInfo(flags, GetString(settings, "secretKey"), GetString(settings, "bindAddress")));
    }

    /// <summary>The named member of an object, or an undefined element for anything else.</summary>
    private static JsonElement Prop(JsonElement el, string name) =>
        el.ValueKind == JsonValueKind.Object && el.TryGetProperty(name, out var v) ? v : default;

    /// <summary>The object entries of the named array; a missing, null or non-array member is empty.</summary>
    private static IEnumerable<JsonElement> Items(JsonElement el, string name) =>
        Prop(el, name) is { ValueKind: JsonValueKind.Array } list
            ? list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object)
            : [];

    internal static string GetString(JsonElement el, string name) =>
        Prop(el, name) is { ValueKind: JsonValueKind.String } v ? v.GetString() ?? "" : "";

    private static bool GetBool(JsonElement el, string name) =>
        Prop(el, name).ValueKind == JsonValueKind.True;

    private static int GetInt(JsonElement el, string name) =>
        Prop(el, name) is { ValueKind: JsonValueKind.Number } v && v.TryGetInt32(out var n) ? n : 0;
}