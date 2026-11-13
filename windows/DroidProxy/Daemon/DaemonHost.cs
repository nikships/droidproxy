using System.Diagnostics;

namespace DroidProxy.Daemon;

/// <summary>
/// Owns the bundled Go daemon process. The daemon tree mirrors the Linux
/// release layout: &lt;root&gt;/bin/droidproxy.exe, &lt;root&gt;/libexec/cli-proxy-api.exe,
/// &lt;root&gt;/share/config.yaml. In development, DROIDPROXY_DAEMON_ROOT or a
/// sibling daemon/ folder next to the app binary provides it.
/// </summary>
public sealed class DaemonHost : IDisposable
{
    private Process? _process;

    public DaemonHost()
    {
        Root = FindRoot();
        var external = Environment.GetEnvironmentVariable("DROIDPROXY_SOCKET");
        IsExternal = !string.IsNullOrWhiteSpace(external);
        SocketPath = IsExternal ? external! : Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "DroidProxy", "control.sock");
    }

    /// <summary>
    /// DROIDPROXY_SOCKET attaches the app to a daemon it does not own, such as
    /// windows/tools/FakeDaemon.cs. The app then never starts or stops one.
    /// </summary>
    public bool IsExternal { get; }
    public string? Root { get; }
    public string SocketPath { get; }
    public bool IsInstalled => DaemonExe is not null;
    public string? DaemonExe => Root is null ? null : Path.Combine(Root, "bin", "droidproxy.exe");
    public bool IsRunning => _process is { HasExited: false };

    public event Action? Exited;

    private static string? FindRoot()
    {
        var candidates = new List<string>();
        var env = Environment.GetEnvironmentVariable("DROIDPROXY_DAEMON_ROOT");
        if (!string.IsNullOrWhiteSpace(env)) candidates.Add(env);
        var baseDir = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(baseDir, "daemon"));
        candidates.Add(baseDir);
        // Development fallback used by the bring-up builds on elsa-x1.
        candidates.Add(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "droidproxy-test"));

        foreach (var candidate in candidates)
        {
            if (File.Exists(Path.Combine(candidate, "bin", "droidproxy.exe")))
                return candidate;
        }
        return null;
    }

    private void Log(string message)
    {
        try
        {
            var dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DroidProxy");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "host.log"),
                $"{DateTimeOffset.Now:O} {message}{Environment.NewLine}");
        }
        catch
        {
            // Best-effort diagnostics only.
        }
    }

    public void Start()
    {
        if (IsExternal) return;
        Log($"Start: root={Root ?? "<null>"} exe={DaemonExe ?? "<null>"} running={IsRunning}");
        if (IsRunning || DaemonExe is null) return;
        Directory.CreateDirectory(Path.GetDirectoryName(SocketPath)!);
        var psi = new ProcessStartInfo
        {
            FileName = DaemonExe,
            Arguments = "serve",
            WorkingDirectory = Root!,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        psi.Environment["DROIDPROXY_ROOT"] = Root!;
        psi.Environment["DROIDPROXY_SOCKET"] = SocketPath;
        try
        {
            _process = Process.Start(psi);
        }
        catch (Exception ex)
        {
            Log($"Process.Start failed: {ex.Message}");
            return;
        }
        Log($"Started daemon pid={_process?.Id}");
        if (_process is not null)
        {
            _process.EnableRaisingEvents = true;
            _process.Exited += (_, _) =>
            {
                Log($"Daemon exited code={_process.ExitCode}");
                Exited?.Invoke();
            };
        }
    }

    /// <summary>Asks the daemon to quit via its control API, then waits briefly.</summary>
    public async Task StopAsync()
    {
        if (IsExternal) return;
        try
        {
            using var client = new DaemonClient(SocketPath);
            await client.CallAsync("app.quit");
        }
        catch (DaemonClient.OfflineException)
        {
            // Already down; fall through to process cleanup.
        }
        if (_process is { HasExited: false })
        {
            if (!_process.WaitForExit(3000))
            {
                _process.Kill(entireProcessTree: true);
            }
        }
        _process = null;
    }

    public void Dispose()
    {
        _process?.Dispose();
    }
}
