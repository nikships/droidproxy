#:sdk Microsoft.NET.Sdk.Web

// Serves the daemon control API from a JSON fixture so the WinUI app can be
// run and inspected without touching a real daemon or its accounts.
// dotnet run FakeDaemon.cs -- <socket-path> <fixture.json>
using System.Text.Json.Nodes;

var socketPath = args[0];
var state = JsonNode.Parse(File.ReadAllText(args[1]))!.AsObject();
var gate = new object();
var tick = 0;
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
        case "model.setEnabled":
            foreach (var model in state["providers"]!.AsArray().SelectMany(n => n!["models"]?.AsArray() ?? []))
                if ((string?)model!["slug"] == (string?)p["slug"]) model["enabled"] = p["enabled"]!.DeepClone();
            break;
    }
}
