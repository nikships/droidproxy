#:sdk Microsoft.NET.Sdk.Web

// Serves the daemon control API from a JSON fixture so the WinUI app can be
// run and inspected without touching a real daemon or its accounts.
// From windows/tools: dotnet run --file FakeDaemon.cs -- <socket-path> fake-state.json
using System.Text.Json.Nodes;

var socketPath = args[0];
var state = JsonNode.Parse(File.ReadAllText(args[1]))!.AsObject();
var gate = new object();
var tick = 0;
var messages = new System.Collections.Concurrent.ConcurrentQueue<JsonObject>();
File.Delete(socketPath);

var builder = WebApplication.CreateSlimBuilder();
builder.Logging.ClearProviders();
builder.WebHost.ConfigureKestrel(o => o.ListenUnixSocket(socketPath));
var app = builder.Build();

string Snapshot() { lock (gate) return state.ToJsonString(); }

app.MapGet("/v1/state", () => Results.Text(Snapshot(), "application/json"));

app.MapGet("/v1/events", async (HttpContext ctx) =>
{
    ctx.Response.ContentType = "application/x-ndjson";
    while (!ctx.RequestAborted.IsCancellationRequested)
    {
        // Same cadence as the real daemon: a full snapshot every second.
        while (messages.TryDequeue(out var message)) await ctx.Response.WriteAsync(message.ToJsonString() + "\n");
        await ctx.Response.WriteAsync($"{{\"type\":\"state\",\"state\":{Snapshot()}}}\n");
        await ctx.Response.Body.FlushAsync();
        Console.WriteLine($"event {Interlocked.Increment(ref tick)}");
        await Task.Delay(1000);
    }
});

app.MapPost("/v1/call/{method}", async (string method, HttpRequest req) =>
{
    var p = (await JsonNode.ParseAsync(req.Body))?.AsObject() ?? new JsonObject();
    lock (gate) Apply(method, p);
    Console.WriteLine($"call {method} {p.ToJsonString()}");
    return Results.Text("{\"ok\":true}", "application/json");
});

app.Run();

void Apply(string method, JsonObject p)
{
    JsonObject? Provider(string? id) =>
        state["providers"]!.AsArray().Select(n => n!.AsObject()).FirstOrDefault(n => (string?)n["id"] == id);
    switch (method)
    {
        case "settings.set":
            state["settings"]![(string)p["key"]!] = p["value"]!.DeepClone();
            break;
        case "server.toggle":
            state["server"]!["running"] = !(bool)state["server"]!["running"]!;
            break;
        case "provider.setEnabled":
            Provider((string?)p["provider"])!["enabled"] = p["enabled"]!.DeepClone();
            break;
        case "account.toggleDisabled":
            var account = Provider((string?)p["provider"])!["accounts"]!.AsArray()
                .First(a => (string?)a!["id"] == (string?)p["accountId"])!;
            account["disabled"] = !(bool)account["disabled"]!;
            break;
        case "provider.connect" when (string?)p["provider"] == "grok":
            // Mirrors the daemon's device-code sign-in: a code and URL appear, then wait for approval.
            Provider("grok")!["authenticating"] = true;
            state["grok"] = new JsonObject
            {
                ["authenticating"] = true,
                ["userCode"] = "FAKE-0000",
                ["verificationUrl"] = "https://example.com/device?user_code=FAKE-0000",
            };
            messages.Enqueue(new JsonObject
            {
                ["type"] = "message", ["title"] = "DroidProxy", ["level"] = "info",
                ["body"] = "Browser opened for Grok login.\n\nIf prompted, enter code: FAKE-0000\n\nWaiting for approval…",
            });
            break;
        case "provider.cancelAuth" when (string?)p["provider"] == "grok":
            Provider("grok")!["authenticating"] = false;
            state["grok"] = new JsonObject { ["authenticating"] = false, ["userCode"] = "", ["verificationUrl"] = "" };
            break;
        case "model.setEnabled":
            foreach (var model in state["providers"]!.AsArray().SelectMany(n => n!["models"]?.AsArray() ?? []))
                if ((string?)model!["slug"] == (string?)p["slug"]) model["enabled"] = p["enabled"]!.DeepClone();
            break;
    }
}
