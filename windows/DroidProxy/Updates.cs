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
    private VelopackAsset? _ready;

    public UpdatesViewModel()
    {
        if (!_manager.IsInstalled)
        {
            Status = "Updates work only in the installed app.";
            return;
        }
        // An update downloaded before the app last stopped without quitting is still on disk.
        if (_manager.UpdatePendingRestart is { } pending) Ready(pending);
        else Status = $"Version {_manager.CurrentVersion}";
        CanCheck = _ready is null;
    }

    public string Status { get; private set => Set(ref field, value); } = "";
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
            UpdateInfo? update;
            try
            {
                update = await _manager.CheckForUpdatesAsync();
            }
            catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                // The windows-latest release does not exist until the first Windows Release run.
                Status = $"Version {_manager.CurrentVersion}. No Windows release is published yet.";
                return;
            }
            if (update is not { } found)
            {
                Status = $"Version {_manager.CurrentVersion} is up to date.";
                return;
            }
            Status = $"Downloading version {found.TargetFullRelease.Version}…";
            await _manager.DownloadUpdatesAsync(found);
            Ready(found.TargetFullRelease);
        }
        catch (HttpRequestException ex) when (ex.StatusCode == System.Net.HttpStatusCode.NotFound)
        {
            Status = "Update download failed: the package was not found.";
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

    private void Ready(VelopackAsset update)
    {
        _ready = update;
        Status = $"Version {update.Version} is ready. It installs when you restart or quit DroidProxy.";
        CanRestart = true;
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
        if (_ready is null) return;
        try
        {
            _manager.WaitExitThenApplyUpdates(_ready, silent: !restart, restart);
        }
        catch
        {
            // Quitting must still work; the next launch finds the update again.
        }
    }
}
