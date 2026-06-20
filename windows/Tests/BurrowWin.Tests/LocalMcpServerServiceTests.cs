using System.Reflection;
using System.Text.Json.Nodes;
using BurrowWin.Models;
using BurrowWin.Services;
using Xunit;

namespace BurrowWin.Tests;

public sealed class LocalMcpServerServiceTests
{
    [Fact]
    public async Task ExecuteToolByNameAsync_RejectsStringConfirm()
    {
        var engine = new FakeMoleEngineService();
        var service = BuildService(engine);
        var arguments = new JsonObject
        {
            ["confirm"] = "true"
        };

        var response = await ExecuteToolAsync(service, "burrow_clean", arguments);

        Assert.True(response.ContainsKey("error"));
        Assert.Contains("confirm", response["error"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, engine.ExecuteCount);
    }

    [Fact]
    public async Task ExecuteToolByNameAsync_RejectsStringHistoryLimit()
    {
        var service = BuildService(new FakeMoleEngineService());
        var arguments = new JsonObject
        {
            ["limit"] = "24"
        };

        var response = await ExecuteToolAsync(service, "burrow_history", arguments);

        Assert.True(response.ContainsKey("error"));
        Assert.Contains("limit", response["error"]!.GetValue<string>(), StringComparison.OrdinalIgnoreCase);
    }

    private static LocalMcpServerService BuildService(FakeMoleEngineService engine)
    {
        return new LocalMcpServerService(
            engine,
            new FakeDiskAnalyzerService(),
            new FakeTelemetrySamplerService(),
            new FakeTelemetryHistoryService(),
            new FakeInstalledApplicationService(),
            new FakeOperationHistoryService(),
            new FakeApplicationSettingsService());
    }

    private static async Task<JsonObject> ExecuteToolAsync(
        LocalMcpServerService service,
        string name,
        JsonObject arguments)
    {
        var method = typeof(LocalMcpServerService).GetMethod(
            "ExecuteToolByNameAsync",
            BindingFlags.Instance | BindingFlags.NonPublic);
        Assert.NotNull(method);

        var task = (Task<JsonObject>)method.Invoke(
            service,
            [name, arguments, CancellationToken.None])!;
        return await task.ConfigureAwait(false);
    }

    private sealed class FakeMoleEngineService : IMoleEngineService
    {
        public int ExecuteCount { get; private set; }

        public MoleEngineAvailability GetAvailability()
        {
            return new MoleEngineAvailability(true, "mole.ps1", MoleEngineKind.PowerShellScript, "available");
        }

        public Task<MoleCommandResult> ExecuteCommandAsync(
            string arguments,
            Action<string>? onProgress = null,
            CancellationToken cancellationToken = default)
        {
            ExecuteCount++;
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }

        public Task<MoleCommandResult> ExecuteAsync(
            IReadOnlyList<string> arguments,
            Action<string>? onProgress = null,
            CancellationToken cancellationToken = default)
        {
            ExecuteCount++;
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }
    }

    private sealed class FakeDiskAnalyzerService : IDiskAnalyzerService
    {
        public Task<DiskUsageNode> AnalyzeAsync(
            string rootPath,
            DiskAnalysisOptions options,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new DiskUsageNode("root", rootPath, 0, 100, []));
        }
    }

    private sealed class FakeTelemetrySamplerService : ISystemTelemetrySamplerService
    {
        public TimeSpan SamplingInterval => TimeSpan.FromSeconds(60);

        public string Source => "test";

        public SystemTelemetrySnapshot? LatestSnapshot => null;

        public Task<SystemTelemetrySnapshot> SampleNowAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult(Snapshot());
        }
    }

    private sealed class FakeTelemetryHistoryService : ISystemTelemetryHistoryService
    {
        public string HistoryFilePath => "history.jsonl";

        public Task RecordAsync(SystemTelemetrySnapshot snapshot, CancellationToken cancellationToken = default)
        {
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<SystemTelemetrySnapshot>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<SystemTelemetrySnapshot>>([]);
        }
    }

    private sealed class FakeInstalledApplicationService : IInstalledApplicationService
    {
        public Task<IReadOnlyList<InstalledApplication>> GetInstalledApplicationsAsync(CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<InstalledApplication>>([]);
        }

        public Task<IReadOnlyList<LeftoverCandidate>> PreviewLeftoversAsync(
            InstalledApplication application,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<LeftoverCandidate>>([]);
        }

        public Task<MoleCommandResult> LaunchUninstallerAsync(
            InstalledApplication application,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult(new MoleCommandResult(0, "ok", string.Empty, false, TimeSpan.Zero));
        }

        public Task<IReadOnlyList<LeftoverRemovalResult>> RemoveLeftoversAsync(
            IEnumerable<LeftoverCandidate> leftovers,
            CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<LeftoverRemovalResult>>([]);
        }
    }

    private sealed class FakeOperationHistoryService : IOperationHistoryService
    {
        public string HistoryFilePath => "activity.jsonl";

        public Task RecordAsync(OperationHistoryEntry entry, CancellationToken cancellationToken = default)
        {
            return Task.CompletedTask;
        }

        public Task<IReadOnlyList<OperationHistoryEntry>> ReadRecentAsync(int limit, CancellationToken cancellationToken = default)
        {
            return Task.FromResult<IReadOnlyList<OperationHistoryEntry>>([]);
        }
    }

    private sealed class FakeApplicationSettingsService : IApplicationSettingsService
    {
        public string SettingsFilePath => "settings.json";

        public BurrowSettings Current { get; } = new()
        {
            HttpServerEnabled = false,
            McpDestructiveActionsEnabled = true
        };

        public event EventHandler<BurrowSettings>? SettingsChanged;

        public Task<BurrowSettings> SaveAsync(BurrowSettings settings, CancellationToken cancellationToken = default)
        {
            SettingsChanged?.Invoke(this, settings);
            return Task.FromResult(settings);
        }

        public BurrowSettings Reload()
        {
            return Current;
        }
    }

    private static SystemTelemetrySnapshot Snapshot()
    {
        return new SystemTelemetrySnapshot(
            DateTimeOffset.UtcNow,
            1,
            2,
            3,
            4,
            5,
            6,
            7,
            8,
            9,
            "GPU 0%",
            []);
    }
}
