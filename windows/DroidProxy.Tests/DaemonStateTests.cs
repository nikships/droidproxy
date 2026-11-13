using DroidProxy.Daemon;

namespace DroidProxy.Tests;

public class DaemonStateParseTests
{
    private static DaemonState Fake() =>
        DaemonState.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "fake-state.json")));

    [Fact]
    public void FakeDaemonSnapshotParses()
    {
        var s = Fake();

        Assert.True(s.ServerRunning);
        Assert.False(s.ServerStarting);
        Assert.Equal(8317, s.ProxyPort);
        Assert.Equal("http://127.0.0.1:8317", s.ServerUrl);
        Assert.Equal("1.0.13", s.App.Version);
        Assert.True(s.FactoryInstalled);
        Assert.Equal(["claude", "codex", "antigravity", "meta", "kimi", "junie", "grok"], s.Providers.Select(p => p.Id));

        var claude = s.Providers[0];
        Assert.Equal("Claude Code", claude.Name);
        Assert.Equal("#D97757", claude.Color);
        Assert.Equal(["alex@example.com", "dev@example.com"], claude.Accounts.Select(a => a.Id));
        Assert.Equal(4, claude.Models.Count);
        Assert.False(claude.Models.Single(m => m.Slug == "haiku-5-5").Enabled);
    }

    [Fact]
    public void UsageCarriesWindowsErrorsAndBankedResets()
    {
        var usage = Fake().Usage;

        Assert.Equal(4, usage.Count);
        Assert.Equal([64, 97], usage[0].Windows.Select(w => w.RemainingPercent));
        Assert.Equal("Token refresh failed", usage[1].Error);
        Assert.Empty(usage[1].Windows);
        Assert.Equal(1, usage.Single(u => u.Provider == "codex").ResetCount);
        Assert.Equal(0, usage[0].ResetCount);
    }

    [Fact]
    public void SettingsKeepBooleansAndStrings()
    {
        var settings = Fake().Settings;

        Assert.True(settings.Flags["gpt6AstraFastMode"]);
        Assert.False(settings.Flags["allowRemote"]);
        Assert.False(settings.Flags.ContainsKey("windowPrimerMinutes.claude"));
        Assert.False(settings.Flags.ContainsKey("bindAddress"));
        Assert.Equal("127.0.0.1", settings.BindAddress);
        Assert.Equal("", settings.SecretKey);
    }

    [Fact]
    public void EmptySnapshotDefaultsEverything()
    {
        var s = DaemonState.Parse("{}");

        Assert.False(s.ServerRunning);
        Assert.Equal(0, s.ProxyPort);
        Assert.Equal("", s.ServerUrl);
        Assert.Equal("", s.App.Version);
        Assert.Empty(s.Providers);
        Assert.Empty(s.Usage);
        Assert.Empty(s.Settings.Flags);
    }

    [Fact]
    public void OfflineEventShapeParsesAsEmpty()
    {
        var s = DaemonState.Parse("""{"type":"offline"}""");

        Assert.False(s.ServerRunning);
        Assert.Empty(s.Providers);
    }

    [Fact]
    public void MissingProviderFieldsDefault()
    {
        var s = DaemonState.Parse("""{"providers":[{"id":"claude"}]}""");

        var p = Assert.Single(s.Providers);
        Assert.Equal("", p.Name);
        Assert.False(p.Enabled);
        Assert.Empty(p.Accounts);
        Assert.Empty(p.Models);
    }

    [Fact]
    public void UnknownProviderIsRenderedGenerically()
    {
        var s = DaemonState.Parse("""
            {"providers":[{"id":"hydrogen","name":"Hydrogen","kind":"standard","enabled":true,
              "accounts":[{"id":"h-1","displayName":"one@example.com","expired":true}],
              "models":[{"slug":"h-1","displayName":"H 1","enabled":true,"installed":false}]}],
             "grok":{"userCode":"GROK-1","verificationUrl":"https://example.com/grok"}}
            """);

        var p = Assert.Single(s.Providers);
        Assert.Equal("Hydrogen", p.Name);
        Assert.True(Assert.Single(p.Accounts).Expired);
        Assert.False(Assert.Single(p.Models).Installed);
        Assert.Equal("", p.DeviceCode);
    }

    [Fact]
    public void DeviceCodesComeFromTheirProviderBlocks()
    {
        var s = DaemonState.Parse("""
            {"providers":[{"id":"grok","authenticating":true},{"id":"meta","authenticating":true}],
             "grok":{"userCode":"GROK-1","verificationUrl":"https://example.com/grok"},
             "meta":{"deviceCode":"META-1","verificationUrl":"https://example.com/meta"}}
            """);

        Assert.Equal(("GROK-1", "https://example.com/grok"), (s.Providers[0].DeviceCode, s.Providers[0].DeviceUrl));
        Assert.Equal(("META-1", "https://example.com/meta"), (s.Providers[1].DeviceCode, s.Providers[1].DeviceUrl));
    }

    [Fact]
    public void NullsReadAsDefaults()
    {
        var s = DaemonState.Parse("""
            {"app":null,"server":{"running":null,"proxyPort":null,"url":null},"paths":null,"factory":null,
             "settings":{"secretKey":null,"beta":null},"grok":null,"meta":null,
             "providers":[null,{"id":"grok","name":null,"accounts":null,"models":[null]}],
             "usage":{"accounts":[null,{"id":"u","windows":[{"title":"5-hour","remainingPercent":null}],"resetCredits":null}]}}
            """);

        Assert.False(s.ServerRunning);
        Assert.Equal(0, s.ProxyPort);
        Assert.Equal("", s.ServerUrl);
        Assert.Equal("", s.Settings.SecretKey);
        Assert.Empty(s.Settings.Flags);
        var grok = Assert.Single(s.Providers);
        Assert.Equal("", grok.Name);
        Assert.Empty(grok.Accounts);
        Assert.Empty(grok.Models);
        var u = Assert.Single(s.Usage);
        Assert.Null(Assert.Single(u.Windows).RemainingPercent);
        Assert.Equal(0, u.ResetCount);
    }

    [Fact]
    public void NonObjectSectionsReadAsDefaults()
    {
        var s = DaemonState.Parse("""{"server":[],"settings":"x","providers":{},"usage":null}""");

        Assert.False(s.ServerRunning);
        Assert.Empty(s.Providers);
        Assert.Empty(s.Usage);
    }
}

public class DaemonClientOfflineTests
{
    private static DaemonClient Missing() =>
        new(Path.Combine(Path.GetTempPath(), $"droidproxy-missing-{Guid.NewGuid():N}.sock"));

    [Fact]
    public async Task StateThrowsOfflineWhenNoDaemonListens()
    {
        using var client = Missing();
        await Assert.ThrowsAsync<DaemonClient.OfflineException>(() => client.GetStateAsync());
    }

    [Fact]
    public async Task CallThrowsOfflineWhenNoDaemonListens()
    {
        using var client = Missing();
        await Assert.ThrowsAsync<DaemonClient.OfflineException>(() => client.CallAsync("server.toggle"));
    }
}
