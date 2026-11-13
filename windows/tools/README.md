# Fake daemon

Runs the control API from `fake-state.json` so the app can be driven and
screenshotted without a real daemon, real accounts, or the live proxy.

```powershell
$sock = "$env:TEMP\droidproxy-fake.sock"
cd windows/tools
dotnet run --file FakeDaemon.cs -- $sock fake-state.json
# then, in another terminal, from the app's output folder
$env:DROIDPROXY_SOCKET = "$env:TEMP\droidproxy-fake.sock"; .\DroidProxy.exe
```

With `DROIDPROXY_SOCKET` set the app attaches to that socket and never starts
or stops a daemon. The fake publishes a full snapshot every second, like the
real one, and applies `settings.set`, `server.toggle`, `provider.setEnabled`,
`account.toggleDisabled` and `model.setEnabled` to its in-memory state.
