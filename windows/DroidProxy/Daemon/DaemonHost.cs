using System.Diagnostics;

namespace DroidProxy.Daemon;

/// <summary>
/// Owns the bundled Go daemon process. The daemon tree mirrors the Linux
/// release layout: &lt;root&gt;/bin/droidproxy.exe, &lt;root&gt;/libexec/cli-proxy-api.exe,
/// &lt;root&gt;/share/config.yaml. In development, DROIDPROXY_DAEMON_ROOT or a
/// sibling daemon/ folder next to the app binary provides it.
/// </summary>
public sealed class DaemonHost
{
    private Process? _process;
    private volatile bool _stopping;

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

    /// <summary>Why the last start failed or the daemon died on its own; empty otherwise.</summary>
    public string Failure { get; private set; } = "";

    private static string? FindRoot()
    {
        var candidates = new List<string>();
        var env = Environment.GetEnvironmentVariable("DROIDPROXY_DAEMON_ROOT");
        if (!string.IsNullOrWhiteSpace(env)) candidates.Add(env);
        var baseDir = AppContext.BaseDirectory;
        candidates.Add(Path.Combine(baseDir, "daemon"));
        candidates.Add(baseDir);

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
        Failure = "";
        _stopping = false;
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
            Failure = $"The daemon could not start: {ex.Message}";
            return;
        }
        Log($"Started daemon pid={_process?.Id}");
        if (_process is { } process)
        {
            process.Exited += (_, _) =>
            {
                Log($"Daemon exited code={process.ExitCode}");
                if (!_stopping) Failure = $"The daemon exited with code {process.ExitCode}.";
            };
            // Subscribe first: a daemon that dies at once can raise Exited as soon as this is set.
            process.EnableRaisingEvents = true;
        }
    }

    /// <summary>Asks the daemon to quit via its control API, giving it three seconds before killing it.</summary>
    public async Task StopAsync()
    {
        // Without a bundled daemon, whatever answers on the socket is not this app's to stop.
        if (IsExternal || !IsInstalled) return;
        _stopping = true;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        try
        {
            using var client = new DaemonClient(SocketPath);
            await client.CallAsync("app.quit", cancellationToken: timeout.Token);
            if (_process is not null) await _process.WaitForExitAsync(timeout.Token);
        }
        catch
        {
            // Down already, no answer, or too slow: the kill below covers every case.
        }
        if (_process is { HasExited: false }) _process.Kill(entireProcessTree: true);
        _process = null;
    }
}
