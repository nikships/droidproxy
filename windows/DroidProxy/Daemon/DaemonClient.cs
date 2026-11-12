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
        SocketPath = socketPath;
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

    public string SocketPath { get; }

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

/// <summary>The slice of the daemon snapshot this app renders today.</summary>
public sealed record DaemonState(
    bool ServerRunning,
    bool ServerStarting,
    int ProxyPort,
    string LastError,
    string Version,
    string UpdateState,
    string LatestVersion,
    IReadOnlyList<DaemonState.ProviderInfo> Providers)
{
    public sealed record ProviderInfo(string Id, string Name, bool Enabled, int AccountCount);

    public static DaemonState Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var server = root.TryGetProperty("server", out var s) ? s : default;
        var app = root.TryGetProperty("app", out var a) ? a : default;
        var update = root.TryGetProperty("update", out var u) ? u : default;

        var providers = new List<ProviderInfo>();
        if (root.TryGetProperty("providers", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var p in list.EnumerateArray())
            {
                var accounts = p.TryGetProperty("accounts", out var acc) && acc.ValueKind == JsonValueKind.Array
                    ? acc.GetArrayLength() : 0;
                providers.Add(new ProviderInfo(
                    GetString(p, "id"), GetString(p, "name"),
                    GetBool(p, "enabled"), accounts));
            }
        }

        return new DaemonState(
            GetBool(server, "running"), GetBool(server, "starting"),
            GetInt(server, "proxyPort"), GetString(server, "lastError"),
            GetString(app, "version"),
            GetString(update, "state"), GetString(update, "latestVersion"),
            providers);
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
