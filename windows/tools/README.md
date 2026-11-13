# Fake daemon

Runs the control API from `fake-state.json` so the app can be driven and
screenshotted without a real daemon, real accounts, or the live proxy.

```powershell
$sock = "$env:TEMP\droidproxy-fake.sock"
dotnet run windows/tools/FakeDaemon.cs -- $sock windows/tools/fake-state.json
$env:DROIDPROXY_SOCKET = $sock; .\DroidProxy.exe
```

With `DROIDPROXY_SOCKET` set the app attaches to that socket and never starts
or stops a daemon. The fake publishes a full snapshot every second, like the
real one, and applies `settings.set`, `server.toggle`, `provider.setEnabled`,
`account.toggleDisabled` and `model.setEnabled` to its in-memory state.
