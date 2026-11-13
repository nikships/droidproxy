# DroidProxy for Windows

Unpackaged WinUI 3 app (.NET 10, Windows App SDK) that fronts the Go daemon.
There is no MSIX manifest; `dotnet build` and the packaged tree are the only
ways it runs.

## Build and run

```powershell
cd windows/DroidProxy
dotnet build -c Debug -p:Platform=x64
```

The app starts `daemon\bin\droidproxy.exe` next to its own exe (or under
`DROIDPROXY_DAEMON_ROOT`) and talks to it over the control socket. A bare build
has no daemon tree, so for UI work run
the fake daemon instead (see `windows/tools/README.md`) and set
`DROIDPROXY_SOCKET`; the app then attaches and never starts or stops one.

## Package

```powershell
pwsh windows/package.ps1 -DaemonRoot <daemon tree with bin, libexec, share> -Version <x.y.z>
```

This runs `vpk pack` (Velopack) and writes the installer, update packages and
`releases.win.json` to `DroidProxy-Windows/` at the repo root, which git
ignores. Releases come from `.github/workflows/windows-release.yml`.

## Layout

| Path | Contents |
|------|----------|
| `Program.cs` | Entry point: Velopack hooks, then WinUI |
| `App.xaml(.cs)` | Theme, tray icon and menu, daemon lifecycle, state watch loop |
| `Updates.cs` | Velopack update check, download and restart-to-update |
| `MainWindow.xaml(.cs)` | Title bar and NavigationView shell |
| `Pages/` | Overview, Providers, Network & remote, Advanced, About |
| `ViewModels.cs` | View models updated in place from each daemon snapshot |
| `Daemon/` | Daemon process host and control-API client |
| `Assets/` | App, tray and provider icons |

Each daemon snapshot is a full state. Update the existing view models with
`SyncKeyed` and `Toggle.Sync`; never rebuild controls from a snapshot, or
switches flash and expanders collapse.
