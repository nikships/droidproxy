using Velopack;
using Velopack.Locators;

namespace DroidProxy;

/// <summary>
/// Velopack updates for the installed app. The feed is one rolling GitHub release because
/// GithubSource reads only the newest ten releases, and the Mac builds push Windows out of them.
/// </summary>
public sealed class UpdatesViewModel : Observable
{
    private const string Feed = "https://github.com/nikships/droidproxy/releases/download/windows-latest";

    // DROIDPROXY_UPDATE_URL points a test install at a local folder or another feed.
    private readonly UpdateManager _manager = new(
        Environment.GetEnvironmentVariable("DROIDPROXY_UPDATE_URL") is { Length: > 0 } url ? url : Feed);
    private UpdateInfo? _ready;

    public UpdatesViewModel()
    {
        CanCheck = _manager.IsInstalled;
        Status = _manager.IsInstalled
            ? $"Version {_manager.CurrentVersion}"
            : "Updates work only in the installed app.";
    }

    public string Status { get; private set => Set(ref field, value); }
    public bool CanCheck { get; private set => Set(ref field, value); }
    public bool CanRestart { get; private set => Set(ref field, value); }

    /// <summary>The launcher Velopack keeps in the install root, which survives updates; null outside an install.</summary>
    public static string? StableExe =>
        VelopackLocator.IsCurrentSet && VelopackLocator.Current.RootAppDir is { } root && Environment.ProcessPath is { } exe
            ? Path.Combine(root, Path.GetFileName(exe))
            : null;

    /// <summary>Checks now, then daily until an update is downloaded. It applies when the app quits.</summary>
    public async Task RunAsync(CancellationToken cancellationToken)
    {
        if (!_manager.IsInstalled) return;
        using var timer = new PeriodicTimer(TimeSpan.FromDays(1));
        do await CheckAsync();
        while (_ready is null && await timer.WaitForNextTickAsync(cancellationToken));
    }

    public async Task CheckAsync()
    {
        if (!CanCheck) return;
        CanCheck = false;
        try
        {
            Status = "Checking for updates…";
            if (await _manager.CheckForUpdatesAsync() is not { } update)
            {
                Status = $"Version {_manager.CurrentVersion} is up to date.";
                return;
            }
            Status = $"Downloading version {update.TargetFullRelease.Version}…";
            await _manager.DownloadUpdatesAsync(update);
            _ready = update;
            Status = $"Version {update.TargetFullRelease.Version} is ready. It installs when you restart or quit DroidProxy.";
            CanRestart = true;
        }
        catch (Exception ex)
        {
            Status = $"Update check failed: {ex.Message}";
        }
        finally
        {
            CanCheck = _ready is null;
        }
    }

    public void Check() => _ = CheckAsync();

    public async void Restart()
    {
        if (_ready is null) return;
        CanRestart = false;
        await App.Current.QuitAsync(restart: true);
    }

    /// <summary>Hands a downloaded update to Velopack, which installs it once this process exits.</summary>
    public void ApplyOnExit(bool restart)
    {
        if (_ready is not { } update) return;
        try
        {
            _manager.WaitExitThenApplyUpdates(update.TargetFullRelease, silent: !restart, restart);
        }
        catch
        {
            // Quitting must still work; the next launch finds the update again.
        }
    }
}
